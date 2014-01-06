http = require 'http'
url = require 'url'
{ EventEmitter } = require 'events'

_ = require 'lodash'

Request = require './request'

module.exports = class Proxy extends EventEmitter
  constructor: (opts = {}) ->
    super()

    @opts = _.clone opts
    _.defaults @opts,
      threads: 12
      partSize: 1024 * 1024 / 4
      contentLength: 1024 * 1024

    @server = http.createServer()
    @server.on 'request', @request
    @server.on 'error', (e) =>
      @emit 'error', e

  _isDownloadable: (res) ->
    res.statusCode in [200, 206] and (parseInt res.headers['content-length']) >= @opts.contentLength

  request: (clientReq, clientRes) =>
    reqOpts = url.parse clientReq.url
    reqOpts.method = clientReq.method
    reqOpts.headers = clientReq.headers
    reqOpts.agent = new http.Agent maxSockets: @opts.threads

    # Create new request
    request = new Request reqOpts, @opts

    # Listen to connect and determine whether to stream download or not
    request.on 'connect', (res, callback) =>
      clientRes.writeHead res.statusCode, res.headers
      callback (@_isDownloadable res)

    # Pipe clientRequest to request, request to clientResponse
    clientReq.pipe request
    request.pipe clientRes

    # Start the request
    request.start()

    # Stop the request whether or not it has completed
    clientRes.on 'close', ->
      request.stop()

  listen: (port, host, callback) ->
    @server.listen port, host, callback
