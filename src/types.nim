type
  OpenAIConfig* = object
    url*: string
    apiKey*: string

  NetworkConfig* = object
    model*: string
    prompt*: string
    maxInflight*: int
    totalTimeoutMs*: int
    maxRetries*: int

  RenderConfig* = object
    renderScale*: float
    webpQuality*: float32

  RuntimeConfig* = object
    inputPath*: string
    selectedPages*: seq[int] # seq_id -> selectedPages[seq_id]
    openaiConfig*: OpenAIConfig
    networkConfig*: NetworkConfig
    renderConfig*: RenderConfig

  PageErrorKind* = enum
    NoError,
    PdfError,
    EncodeError,
    NetworkError,
    Timeout,
    RateLimit,
    HttpError,
    ParseError

  PageResultStatus* = enum
    PagePending = "pending",
    PageOk = "ok",
    PageError = "error"

  PageResult* = object
    page*: int
    attempts*: int
    status*: PageResultStatus
    text*: string
    errorKind*: PageErrorKind
    errorMessage*: string
    httpStatus*: int
