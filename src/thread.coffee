http = require 'http'
{ Duplex } = require 'stream'

_ = require 'lodash'

createRange = (start = 0, end = null) ->
  if end is null
    return "bytes=#{start}-"
  else
    return "bytes=#{start}-#{end}"

parseContentRange = (str = null) ->
  return null if str is null
  match = str.match /bytes ([0-9]+)-([0-9]+)\/([0-9]+)/
  range = [(parseInt match[1]), (parseInt match[2]), (parseInt match[3])]
  return range

module.exports = class Thread extends Duplex
  constructor: (offset, length, reqOpts, opts) ->
    super()

    @_reading = false
    @_readable = false
    @_tries = 0

    @connecting = false
    @connected = false

    @range = [offset, offset + length]
    @offset = offset

    @reqOpts = _.clone reqOpts
    @reqOpts.headers = _.clone reqOpts.headers

    @opts = _.clone opts

  # Tries to connect
  _connect: ->
    @connecting = true

    # Set range header
    if @range[0] isnt 0
      end = if @opts.endOffset then (@opts.endOffset - 1) else null
      @reqOpts.headers['range'] = createRange @offset, end
    else if @reqOpts.headers['range']
      delete @reqOpts.headers['range']

    # Create request
    @_req = http.request @reqOpts

    # Listen to response
    @_req.on 'response', (@_res) =>
      @connected = true
      @connecting = false

      range = parseContentRange @_res.headers['content-range']

      @length = (parseInt @_res.headers['content-length']) or null

      # Parse and validate range
      if (range and (range[0] isnt @offset)) or (not range and @offset isnt 0)
        console.log "received invalid range: #{range}, expected #{@offset},#{@offset + @length - 1}"
        return

      # Push data when available
      @_res.on 'readable', =>
        @_readable = true
        @_readRes() if @_reading

      @_res.on 'end', =>
        if @offset is @range[1]
          @push null
        else
          @connected = false
          # Notify the user
          @emit 'disconnect'

      @emit 'connect', @_res 

    @_req.on 'error', (e) =>
      @emit 'error', e

  _readRes: ->
    data = @_res.read()
    if data
      @_reading = @push data 
      @offset += data.length

    if not @crossed and @offset >= @range[1]
      @crossed = true
      @emit 'cross'

  _read: ->
    @_reading = true
    @_readRes() if @_readable

  _write: (chunk, encoding, callback) ->
    @_req.write chunk, encoding, callback

  # Starts the thread
  start: ->
    @_connect()

  # Stops the thread
  stop: ->
    @_readable = false
    @connecting = false
    @connected = false

    @_req.removeAllListeners()
    @_req.on 'error', (e) -> console.log 'req error', e # Dummy error listener
    @_req.connection.destroy()

    if @_res
      @_res.removeAllListeners()
      @_res.on 'error', (e) -> console.log 'res error', e # Dummy error listener
      @_res.connection.destroy()

  # Ends the request
  end: ->
    @_req.end()
