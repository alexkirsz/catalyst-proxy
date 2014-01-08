http = require 'http'
url = require 'url'
{ Duplex } = require 'stream'

_ = require 'lodash'
Multisource = require 'multisource-stream'

Thread = require './thread'

parseRange = (str = null) ->
  return null if str is null
  match = str.match /bytes=([0-9]+)?-([0-9]+)?/
  return false unless match[1]
  range = [(parseInt match[1]), (parseInt match[2]) or null]
  return range

module.exports = class Request extends Duplex
  constructor: (reqOpts, opts) ->
    super()

    @reqOpts = _.clone reqOpts
    @reqOpts.headers = _.clone reqOpts.headers

    @opts = _.clone opts

    # Parse and setup initial range
    range = parseRange @reqOpts.headers['range']
    if range is false
      throw new Error "unsupported range header: #{@reqOpts.headers['range']}"
    else if range
      @range = [range[0], if range[1] then (range[1] + 1) else null]
    else
      @range = [0, null]

    @readOffset = 0
    @offset = @range[0]

    @pool = []
    @offsets = []
    @runningPool = []

    # Create a multisource stream and set its start offset at the range's start
    @stream = new Multisource highWaterMark: @opts.partSize
    @stream.offset = @offset

    # Push data when available
    @stream.on 'readable', =>
      @_readable = true
      @_readStream() if @_reading

  _createThread: (offset, length) ->
    thread = new Thread offset, length, @reqOpts, endOffset: @range[1]

    # Insert the thread at the correct place in the pool
    idx = _.sortedIndex @offsets, offset
    @offsets.splice idx, 0, offset
    @pool.splice idx, 0, thread

    # Pipe the thread to the stream from its offset
    thread.pipe (@stream.from offset, highWaterMark: @opts.partSize)

    return thread

  start: ->
    # Calculate correct thread length
    length = if @range[1] then (@range[1] - @offset) else Infinity
    length = @opts.partSize if length > @opts.partSize

    # Create the thread at current offset
    thread = @_createThread @offset, length

    thread.once 'connect', (res) =>
      # Retrieve the length from the thread
      @length = thread.length
      # Set correct end range
      @range[1] = @range[0] + @length

      # Emit connect and let the user decide of the downloading mode
      called = false
      @emit 'connect', res, (streaming) =>
        if called
          throw new Error 'connect callback has already been called'
        else
          called = true

        if streaming
          @_streamingMode()
        else
          thread.on 'end', => @push null
          thread.on 'disconnect', => @push null

    thread.on 'error', ->
      @push null

    # Start the thread
    thread.start()
    @runningPool.push thread

    # Increment offset
    @offset += length

  # Ends the first thread's request
  end: ->
    @pool[0].end()

  # Stops the request
  stop: ->
    thread.stop() for thread in @runningPool

    @pool = []
    @offsets = []
    @runningPool = []

    @offset = @readOffset
    @range[0] = @readOffset
    @readOffset = 0

  _readStream: ->
    data = @stream.read()
    if data
      @readOffset += data.length
      @_reading = @push data
      @push null if @readOffset is @range[1]

  _read: ->
    @_reading = true
    @_readStream() if @_readable

  _write: (chunk, encoding, callback) ->
    # Write data to the first thread (this means the request has a body, not GET)
    @pool[0].write chunk, encoding, callback

  # Switches to threaded streaming downloading
  _streamingMode: ->
    # Retrieve initial thread
    thread = @pool[0]
    # Setup correct thread range
    thread.range[1] = thread.range[0] + @opts.partSize
    # Set the offset at the end of the thread range
    @offset = thread.range[1]

    @_bindThread @pool[0]
    @_fill()

  # Returns the next thread in the thread pool
  _getNextThread: (thread) ->
    @pool[(@pool.indexOf thread) + 1] or null

  # Binds event listeners to a thread
  _bindThread: (thread) ->
    thread.on 'cross', =>
      next = @_getNextThread thread

      if not next and thread.range[1] isnt @range[1]
        # The most recent running thread has ended, extend it
        thread.range[1] += @opts.partSize
        thread.crossed = false
        @offset += @opts.partSize
      else if next and not next.connected and not next.crossed
        # The next thread isn't running and hasn't completed, replace it
        thread.range[1] = next.range[1]
        thread.crossed = false
        @_removeThread next, true
        @_fill()
      else
        # The next thread is running or has completed, remove this thread
        @_removeThread thread
        @_fill()

    thread.on 'disconnect', =>
      @_restartThread()

    thread.on 'error', =>
      @_restartThread()

  _restartThread: (thread) ->
    # Clean up
    thread.stop()
    # Restart the thread
    thread.start()
    # End the thread's request
    thread.end()

  # Stops and removes a thread from the running pool
  _removeThread: (thread, hard = false) ->
    threadIdx = @pool.indexOf thread
    runningIdx = @runningPool.indexOf thread

    if runningIdx isnt -1
      thread.stop()
      @runningPool.splice runningIdx, 1

    if hard
      # Also remove from the thread pool
      threadIdx = @pool.indexOf thread
      @pool.splice threadIdx, 1

  # Fills the running thread pool
  _fill: ->
    if @runningPool.length < @opts.threads and @offset isnt @range[1]
      # Calculate correct thread length
      length = @range[1] - @offset
      length = @opts.partSize if length > @opts.partSize

      thread = @_createThread @offset, length

      # Continue filling on thread connect
      thread.once 'connect', => @_fill()
      # If the thread is redirected, change request options and restart it
      thread.on 'redirect', (res) =>
        location = url.parse res.headers['location']
        _.extend @reqOpts, location
        _.extend thread.reqOpts, location
        @_restartThread thread
      # Bind thread events
      @_bindThread thread

      # Start the thread
      thread.start()
      @runningPool.push thread

      # Call end on the thread to end its request
      thread.end()

      # Increment offset
      @offset += length
