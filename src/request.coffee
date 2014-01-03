http = require 'http'
url = require 'url'

_ = require 'lodash'
async = require 'async'
Multisource = require 'multisource-stream'

isDownloadable = (res, opts) ->
  res.statusCode in [200, 206] and (parseInt res.headers['content-length']) > opts.contentLength

module.exports = class Request
  constructor: (opts, @_req, @_res) ->
    @opts = _.clone opts
    @opts.headers = _.clone opts.headers

    _.defaults @opts,
      concurrent: 4
      partSize: 1024 * 1024 * 4
      contentLength: 1024 * 1024 * 4

    req = http.request @opts
    # Dummy error listener to avoid uncaught exception
    req.on 'error', ->
    if opts.method is 'GET'
      req.on 'response', (res) =>
        if isDownloadable res, @opts
          @_part req, res
        else
          @_through res
    else
      req.on 'response', (res) => @_through res
    @_req.pipe req

  _through: (res) ->
    @_res.writeHeader res.statusCode, res.headers
    res.pipe @_res

  _setRange: (opts, start, end = '') ->
    opts.headers['range'] = "bytes=#{start}-#{end}"

  _getRange: (res) ->
    return null if not res.headers['content-range']
    raw = res.headers['content-range'].match /bytes ([0-9]+)-([0-9]+)\/([0-9]+)/
    range = [(parseInt raw[1]), (parseInt raw[2])]
    return range

  _part: (req, res) ->
    @_res.writeHeader res.statusCode, res.headers

    @source = new Multisource
    @source.pipe @_res

    # Retrieve content length
    @_length = parseInt res.headers['content-length']
    # Retrieve initial range
    @_offset = if res.statusCode is 206 then (@_getRange res)[0] else 0

    console.log "PART - #{@_length} at offset #{@_offset}"

    thread = { offset: 0, length: @opts.partSize, dlength: 0, running: true, req }
    thread.opts = _.clone @opts
    thread.opts.headers = _.clone @opts.headers
    res.headers['content-range'] = "bytes 0-#{@_length - 1}/#{@_length}"

    # Setup initial thread
    @_gaps = [[@opts.partSize + @_offset, @_length]]
    @_pool = [res]
    @_running = 1

    @_bind thread, res, (e) =>
      # Start filling thread pool
      @_fill()

  _thread: (offset, length, callback) ->
    thread = { offset, length, dlength: 0, running: true }
    console.log "THREAD CREATE - #{thread.offset} to #{thread.offset + thread.length}"

    # Add range header and create a request
    thread.opts = _.clone @opts
    thread.opts.headers = _.clone @opts.headers
    @_setRange thread.opts, offset # Open range, in case the next thread doesn't start before that one ends
    thread.req = http.request thread.opts

    thread.req.on 'response', (res) => @_bind thread, res, callback
    thread.req.on 'error', (e) =>
      console.log 'req error', e
      @_stop thread
    thread.req.on 'end', =>
      console.log 'req error', e
      @_stop thread
    @_pool.push thread

    @_running++
    thread.running = true
    thread.req.end()

  _bind: (thread, res, callback) ->
    console.log "THREAD BIND - #{thread.offset} to #{thread.offset + thread.length}"

    thread.res = res

    range = @_getRange res
    unless range
      @_stop thread
      callback 'RANGE'
      return

    console.log "THREAD RANGE - #{range[0]} to #{range[1]}, expected #{thread.offset} to #{@_length - 1}"
    console.log "THREAD RANGE - sent #{thread.opts.headers['range']}"
    console.log "THREAD RANGE - received #{thread.res.headers['content-range']}"

    # In case the server returned a wrong range
    if range[0] isnt thread.offset
      @_gaps.push [thread.offset, range[0] - thread.offset]
      @_fill()
      thread.offset = range[0]

    # Create a new source from the thread offset (should support negative offset)
    thread.source = @source.from thread.offset - @_offset

    res.on 'data', (chunk) =>
      thread.source.write chunk
      thread.dlength += chunk.length

      if thread.dlength > thread.length
        console.log "THREAD CROSS - #{thread.offset} to #{thread.offset + thread.length}"
        # The thread has passed its assigned length
        next = @_pool[(@_pool.indexOf thread) + 1]
        if not next
          @_stop thread
          @_fill()
        else if next.dlength is 0
          # If the next thread hasn't started, we abort it and continue with the current thread instead
          @_stop next
          @_pool.splice (@_pool.indexOf next), 1
          thread.length += next.length
          console.log "THREAD EXTEND - #{thread.offset} to #{thread.offset + thread.length}"
        else
          console.log "THREAD STOP - #{thread.offset} to #{thread.offset + thread.length}"
          # Else stop the thread
          @_stop thread

    res.on 'error', (e) =>
      console.log "THREAD ERROR - #{thread.offset} to #{thread.offset + thread.length}, #{thread.dlength}/#{thread.length}"
      @_stop thread
    res.on 'end', =>
      console.log "THREAD END - #{thread.offset} to #{thread.offset + thread.length}, #{thread.dlength}/#{thread.length}"
      @_stop thread

    callback()

  _stop: (thread) ->
    return unless thread.running
    thread.running = false
    @_running--

    # If the thread hasn't completed, create a gap
    if thread.dlength < thread.length
      @_gaps.push [thread.offset + thread.dlength, thread.offset + thread.length]

    if thread.req
      thread.req.removeAllListeners()
      # Dummy error listener to avoid uncaught exception
      thread.req.on 'error', ->
      thread.req.abort()

    if thread.res
      thread.res.removeAllListeners()
      # Dummy error listener to avoid uncaught exception
      thread.res.on 'error', ->
      thread.res.socket.destroy()

    @_fill()

  _fill: ->
    async.whilst (=> @_running < @opts.concurrent and @_gaps.length > 0), (next) =>
      gap = @_gaps[@_gaps.length - 1]
      unless gap
        next 'END'
        return

      offset = gap[0]
      length = gap[1] - gap[0]

      if length > @opts.partSize
        # Adjust to the wanted thread size
        length = @opts.partSize
        gap[0] += length
      else
        # The gap is filled 
        @_gaps.splice @_gaps.length - 1, 1

      @_thread offset, length, (e) ->
        next e
    , =>
      console.log "FILLED - #{@_running}/#{@opts.concurrent}, #{@_gaps.length} gaps left"
