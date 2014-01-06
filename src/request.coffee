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
    console.log 'parsed', range, 'from', @reqOpts.headers['range']
    if range is false
      throw new Error "unsupported range header: #{@reqOpts.headers['range']}"
    else if range
      @range = [range[0], if range[1] then (range[1] + 1) else null]
    else
      @range = [0, null]

    @offset = @range[0]

    @connecting = false
    @connected = false

    @pool = []
    @offsets = []
    @runningPool = []

    # Create a multisource stream and set its start offset at the range's start
    @stream = new Multisource
    @stream.offset = @offset

    # Push data when available
    @stream.on 'readable', =>
      @_readable = true
      @_readStream() if @_reading

    # When the stream ends, end the request as well
    @stream.on 'end', =>
      @push null

  _createThread: (offset, length) ->
    console.log "CREATE #{@pool.length} from #{offset} til #{offset + length}"

    thread = new Thread offset, length, @reqOpts, endOffset: @range[1]

    # Insert the thread at the correct place in the pool
    idx = _.sortedIndex @offsets, offset
    @offsets.splice idx, 0, offset
    @pool.splice idx, 0, thread

    # Pipe the thread to the stream from its offset
    thread.pipe (@stream.from offset)

    return thread

  start: ->
    @connecting = true

    # Calculate correct thread length
    length = if @range[1] then (@range[1] - @offset) else Infinity
    length = @opts.partSize if length > @opts.partSize

    # Create the thread at current offset
    thread = @_createThread @offset, length

    thread.once 'connect', (res) =>
      @connecting = false
      @connected = true

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
          console.log 'STREAM', (url.format @reqOpts), @length, @range
          @_streamingMode()
        else
          console.log 'THROUGH', (url.format @reqOpts), @length, @range
          thread.on 'end', => @stream.end()
          thread.on 'disconnect', => @stream.end()

    thread.on 'error', (e) =>
      console.log 'ERROR, cancelling thread'
      @stream.end()

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
    @connecting = false
    @connected = false

    thread.stop() for thread in @runningPool

    @pool = []
    @offsets = []
    @runningPool = []

    @offset = @stream.offset
    @range[0] = @stream.offset

  _readStream: ->
    data = @stream.read()
    @_reading = @push data if data

  _read: ->
    @_reading = true
    @_readStream() if @_readable

  _write: (chunk, encoding, callback) ->
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
      console.log 'CROSS', (@pool.indexOf thread)
      next = @_getNextThread thread

      if not next
        console.log @stream.offset, @range[1], @runningPool.length
        if @stream.offset is @range[1]
          @_onEnd()
        else
          thread.range[1] += @opts.partSize
          thread.crossed = false
      else if not next.connected
        # Replacing the next thread
        thread.range[1] = next.range[1]
        thread.crossed = false
        @_removeThread next, true
        @_fill()
      else
        @_removeThread thread
        @_fill()

    thread.on 'disconnect', =>
      # Clean up
      thread.stop()
      # Restart the thread
      thread.start()
      # End the thread's request
      thread.end()

      console.log 'trying to reconnect'
      thread.once 'connect', =>
        console.log 'successfully reconnected'

    thread.on 'error', =>
      # Clean up
      thread.stop()
      # Restart the thread
      thread.start()
      # End the thread's request
      thread.end()

      console.log 'trying to reconnect'
      thread.once 'connect', =>
        console.log 'successfully reconnected'

  # Stops and removes a thread from the running pool
  _removeThread: (thread, hard = false) ->
    threadIdx = @pool.indexOf thread
    runningIdx = @runningPool.indexOf thread
    console.log "REMOVE #{threadIdx}"

    if runningIdx isnt -1
      thread.stop()
      @runningPool.splice runningIdx, 1

    if hard
      # Also remove from the thread pool
      threadIdx = @pool.indexOf thread
      @pool.splice threadIdx, 1

  # Fills the running thread pool
  _fill: ->
    console.log "FILL #{@runningPool.length}/#{@opts.threads}, #{@offset}/#{@range[1]}, #{@pool.indexOf @runningPool[0]}"
    if @runningPool.length < @opts.threads and @offset isnt @range[1]
      # Calculate correct thread length
      length = @range[1] - @offset
      length = @opts.partSize if length > @opts.partSize

      thread = @_createThread @offset, length

      # Continue filling on thread connect
      thread.once 'connect', => @_fill()
      # Bind thread events
      @_bindThread thread

      # Start the thread
      thread.start()
      @runningPool.push thread

      # Call end on the thread to end its request
      thread.end()

      # Increment offset
      @offset += length

  _onEnd: ->
    @connected = false
    console.log "END #{@offset}/#{@range[1]}"
    @stream.end()
