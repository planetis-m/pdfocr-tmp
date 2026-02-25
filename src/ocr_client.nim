import std/[asyncdispatch, base64, json, strutils]
import pocketflow/llm
import pocketflow/errors
import ./[constants, types]

const
  CompletionSuffix = "/chat/completions"
  RetryableStatuses = [500, 502, 503, 504]

type
  OcrErrorInfo = object
    kind: PageErrorKind
    message: string
    httpStatus: int

proc pageErrorResult(pageNumber, attempts: int; info: OcrErrorInfo): PageResult =
  result = PageResult(
    page: pageNumber,
    attempts: attempts,
    status: PageError,
    text: "",
    errorKind: info.kind,
    errorMessage: info.message,
    httpStatus: info.httpStatus
  )

proc pageOkResult(pageNumber, attempts: int; text: string): PageResult =
  result = PageResult(
    page: pageNumber,
    attempts: attempts,
    status: PageOk,
    text: text,
    errorKind: NoError,
    errorMessage: "",
    httpStatus: 0
  )

proc bytesToString(data: seq[byte]): string =
  result = newString(data.len)
  if data.len > 0:
    copyMem(addr result[0], unsafeAddr data[0], data.len)

proc normalizeBaseUrl(url: string): string =
  if url.endsWith(CompletionSuffix):
    result = url[0..<(url.len - CompletionSuffix.len)]
  else:
    result = url

proc isRetryableHttpStatus(status: int): bool =
  for code in RetryableStatuses:
    if status == code:
      return true
  result = false

proc buildUserMessage(prompt: string; webpPayload: seq[byte]): JsonNode =
  let base64Image = encode(bytesToString(webpPayload))
  let imageDataUrl = "data:image/webp;base64," & base64Image
  result = %*[
    {
      "role": "user",
      "content": [
        {"type": "text", "text": prompt},
        {"type": "image_url", "image_url": {"url": imageDataUrl}}
      ]
    }
  ]

proc timedChat(client: LlmClient; messages: JsonNode; options: LlmOptions;
    timeoutMs: int): Future[string] {.async.} =
  let chatFuture = client.chatWithOptions(messages, options)
  let timeoutFuture = sleepAsync(timeoutMs)

  await chatFuture or timeoutFuture
  if chatFuture.finished:
    result = await chatFuture
  else:
    raise newTimeoutError("request timed out", timeoutMs)

proc classifyOcrError(err: ref CatchableError): OcrErrorInfo =
  if err of RateLimitError:
    result = OcrErrorInfo(kind: RateLimit, message: err.msg, httpStatus: 429)
  elif err of TimeoutError:
    result = OcrErrorInfo(kind: Timeout, message: err.msg, httpStatus: 0)
  elif err of LLMError:
    let llmErr = cast[ref LLMError](err)
    if llmErr.statusCode > 0:
      var msg = llmErr.msg
      if llmErr.responseBody.len > 0:
        msg.add("; response_body=" & llmErr.responseBody)
      result = OcrErrorInfo(kind: HttpError, message: msg, httpStatus: llmErr.statusCode)
    else:
      result = OcrErrorInfo(kind: NetworkError, message: llmErr.msg, httpStatus: 0)
  elif err of JsonParsingError or err of JsonKindError or err of KeyError:
    result = OcrErrorInfo(kind: ParseError, message: err.msg, httpStatus: 0)
  else:
    result = OcrErrorInfo(kind: NetworkError, message: err.msg, httpStatus: 0)

proc shouldRetry(info: OcrErrorInfo): bool =
  case info.kind
  of Timeout, RateLimit, NetworkError:
    result = true
  of HttpError:
    result = isRetryableHttpStatus(info.httpStatus)
  else:
    result = false

proc retryBackoffMs(attemptNumber: int): int =
  let step = min(max(attemptNumber - 1, 0), 4)
  let shifted = 200 shl step
  result = min(shifted, 2000)

proc ocrWebpPage*(pageNumber: int; webpPayload: seq[byte];
    openaiConfig: OpenAIConfig; networkConfig: NetworkConfig): Future[PageResult] {.async.} =
  let baseUrl = normalizeBaseUrl(openaiConfig.url)
  let client = newLlmClient(
    provider = Custom,
    baseUrl = baseUrl,
    apiKey = openaiConfig.apiKey,
    model = networkConfig.model
  )
  defer:
    close(client)

  let options = LlmOptions(
    temperature: 0.0,
    maxTokens: MaxOutputTokens,
    topP: 1.0,
    stream: false,
    useCache: false,
    timeout: networkConfig.totalTimeoutMs
  )
  let messages = buildUserMessage(networkConfig.prompt, webpPayload)
  let maxAttempts = networkConfig.maxRetries + 1
  var attempts = 0
  var finalError = OcrErrorInfo(kind: NetworkError, message: "unknown error", httpStatus: 0)

  for attempt in 1..maxAttempts:
    attempts = attempt
    try:
      let responseText = await timedChat(client, messages, options,
        networkConfig.totalTimeoutMs)
      return pageOkResult(pageNumber, attempts, responseText)
    except CatchableError as err:
      let info = classifyOcrError(err)
      finalError = info
      let canRetry = attempt < maxAttempts and shouldRetry(info)
      if canRetry:
        await sleepAsync(retryBackoffMs(attempt))

  result = pageErrorResult(pageNumber, attempts, finalError)
