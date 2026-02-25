import std/[asyncdispatch, json, options, os, strutils]
import ./[constants, logging, ocr_client, pdf_render, pdfium_wrap, runtime_config, types]

type
  PageTask = object
    seqIndex: int
    future: Future[PageResult]

  RunState = object
    nextToWrite: int
    hadErrors: bool

proc statusText(status: PageResultStatus): string =
  case status
  of PagePending:
    result = "pending"
  of PageOk:
    result = "ok"
  of PageError:
    result = "error"

proc errorKindText(kind: PageErrorKind): string =
  case kind
  of NoError:
    result = "NoError"
  of PdfError:
    result = "PdfError"
  of EncodeError:
    result = "EncodeError"
  of NetworkError:
    result = "NetworkError"
  of Timeout:
    result = "Timeout"
  of RateLimit:
    result = "RateLimit"
  of HttpError:
    result = "HttpError"
  of ParseError:
    result = "ParseError"

proc pageResultToJson(resultValue: PageResult): JsonNode =
  result = %*{
    "page": resultValue.page,
    "attempts": resultValue.attempts,
    "status": statusText(resultValue.status),
    "text": resultValue.text,
    "errorKind": errorKindText(resultValue.errorKind),
    "errorMessage": resultValue.errorMessage,
    "httpStatus": resultValue.httpStatus
  }

proc renderErrorResult(pageNumber: int; kind: PageErrorKind; message: string): PageResult =
  result = PageResult(
    page: pageNumber,
    attempts: 1,
    status: PageError,
    text: "",
    errorKind: kind,
    errorMessage: message,
    httpStatus: 0
  )

proc writeJsonl(resultValue: PageResult) =
  stdout.writeLine($pageResultToJson(resultValue))
  flushFile(stdout)

proc waitForCompletedTask(activeTasks: seq[PageTask]): Future[int] {.async.} =
  result = -1
  while result < 0:
    for idx in 0..<activeTasks.len:
      if activeTasks[idx].future.finished:
        result = idx
        break
    if result < 0:
      await sleepAsync(5)

proc flushReady(pending: var seq[Option[PageResult]]; state: var RunState) =
  while state.nextToWrite < pending.len and pending[state.nextToWrite].isSome:
    let pageResult = pending[state.nextToWrite].get()
    writeJsonl(pageResult)
    if pageResult.status == PageError:
      state.hadErrors = true
    pending[state.nextToWrite] = none(PageResult)
    inc state.nextToWrite

proc runPdfocr(cliArgs: seq[string]): Future[int] {.async.} =
  let runtime = buildRuntimeConfig(cliArgs)
  var state = RunState(nextToWrite: 0, hadErrors: false)
  let maxInflight = max(runtime.networkConfig.maxInflight, 1)
  var pending = newSeq[Option[PageResult]](runtime.selectedPages.len)
  var activeTasks: seq[PageTask] = @[]

  initPdfium()
  var doc: PdfDocument
  try:
    doc = loadDocument(runtime.inputPath)
    for seqIndex in 0..<runtime.selectedPages.len:
      let pageNumber = runtime.selectedPages[seqIndex]
      try:
        let bitmap = renderPageBitmap(doc, pageNumber, runtime.renderConfig.renderScale)
        let webpPayload = encodePageBitmap(bitmap, runtime.renderConfig.webpQuality)
        let taskFuture = ocrWebpPage(pageNumber, webpPayload,
          runtime.openaiConfig, runtime.networkConfig)
        activeTasks.add(PageTask(seqIndex: seqIndex, future: taskFuture))
      except IOError as err:
        pending[seqIndex] = some(renderErrorResult(pageNumber, PdfError, err.msg))
      except ValueError as err:
        pending[seqIndex] = some(renderErrorResult(pageNumber, EncodeError, err.msg))
      except CatchableError as err:
        pending[seqIndex] = some(renderErrorResult(pageNumber, PdfError, err.msg))

      flushReady(pending, state)
      if activeTasks.len >= maxInflight:
        let completedIndex = await waitForCompletedTask(activeTasks)
        let completedTask = activeTasks[completedIndex]
        pending[completedTask.seqIndex] = some(completedTask.future.read)
        activeTasks.delete(completedIndex)
        flushReady(pending, state)

    while activeTasks.len > 0:
      let completedIndex = await waitForCompletedTask(activeTasks)
      let completedTask = activeTasks[completedIndex]
      pending[completedTask.seqIndex] = some(completedTask.future.read)
      activeTasks.delete(completedIndex)
      flushReady(pending, state)
  finally:
    close(doc)
    destroyPdfium()

  result = ExitAllOk
  if state.hadErrors:
    result = ExitPartialFailure

when isMainModule:
  var exitCode = ExitFatalRuntime
  try:
    exitCode = waitFor runPdfocr(commandLineParams())
  except CatchableError as err:
    let cleanMessage = err.msg.splitLines()[0]
    logError(cleanMessage)
    exitCode = ExitFatalRuntime
  quit(exitCode)
