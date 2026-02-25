import std/[asyncdispatch, json, options, os, strutils]
import ./[constants, logging, ocr_client, pdf_render, pdfium_wrap, runtime_config, types]
when not defined(windows):
  import std/posix

type
  PageTask = object
    seqIndex: int
    future: Future[PageResult]

  RunState = object
    nextToWrite: int
    hadErrors: bool

  MemoryTracker = ref object
    peakOccupied: int
    peakTotal: int
    peakRssBytes: int

proc newMemoryTracker(): MemoryTracker =
  result = MemoryTracker(peakOccupied: 0, peakTotal: 0, peakRssBytes: 0)

proc peakRssBytes(): int =
  when defined(windows):
    result = 0
  else:
    var usage: RUsage
    let status = getrusage(RUSAGE_SELF, addr usage)
    if status == 0:
      when defined(macosx):
        result = int(usage.ru_maxrss)
      else:
        result = int(usage.ru_maxrss) * 1024
    else:
      result = 0

proc updateMemoryTracker(tracker: MemoryTracker) =
  if tracker.isNil:
    return
  let occupied = getOccupiedMem()
  let total = getTotalMem()
  let rss = peakRssBytes()
  if occupied > tracker.peakOccupied:
    tracker.peakOccupied = occupied
  if total > tracker.peakTotal:
    tracker.peakTotal = total
  if rss > tracker.peakRssBytes:
    tracker.peakRssBytes = rss

proc mibString(bytes: int): string =
  let mib = float(bytes) / (1024.0 * 1024.0)
  result = formatFloat(mib, ffDecimal, 2)

proc reportMemoryUsage(phase: string; tracker: MemoryTracker) =
  updateMemoryTracker(tracker)
  let occupied = getOccupiedMem()
  let free = getFreeMem()
  let total = getTotalMem()
  logInfo("memory " & phase & ": occupied=" & $occupied & "B (" & mibString(occupied) &
    " MiB)" &
    ", free=" & $free & "B (" & mibString(free) & " MiB)" &
    ", total=" & $total & "B (" & mibString(total) & " MiB)" &
    ", peak_occupied=" & $tracker.peakOccupied & "B (" &
      mibString(tracker.peakOccupied) & " MiB)" &
    ", peak_total=" & $tracker.peakTotal & "B (" &
      mibString(tracker.peakTotal) & " MiB)" &
    ", peak_rss=" & $tracker.peakRssBytes & "B (" &
      mibString(tracker.peakRssBytes) & " MiB)")

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

proc runPdfocr(cliArgs: seq[string]; tracker: MemoryTracker): Future[int] {.async.} =
  let runtime = buildRuntimeConfig(cliArgs)
  reportMemoryUsage("startup", tracker)
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
      updateMemoryTracker(tracker)

    while activeTasks.len > 0:
      let completedIndex = await waitForCompletedTask(activeTasks)
      let completedTask = activeTasks[completedIndex]
      pending[completedTask.seqIndex] = some(completedTask.future.read)
      activeTasks.delete(completedIndex)
      flushReady(pending, state)
      updateMemoryTracker(tracker)
  finally:
    close(doc)
    destroyPdfium()

  reportMemoryUsage("after_pipeline", tracker)
  result = ExitAllOk
  if state.hadErrors:
    result = ExitPartialFailure

when isMainModule:
  var exitCode = ExitFatalRuntime
  let tracker = newMemoryTracker()
  try:
    exitCode = waitFor runPdfocr(commandLineParams(), tracker)
  except CatchableError as err:
    let cleanMessage = err.msg.splitLines()[0]
    logError(cleanMessage)
    exitCode = ExitFatalRuntime
  finally:
    reportMemoryUsage("shutdown", tracker)
  quit(exitCode)
