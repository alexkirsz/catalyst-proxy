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

    if typeof @opts.proxy is 'string'
      protocol = @opts.proxy.match /^([A-Za-z]+)\:\/\//
      @opts.proxy = "http://#{@opts.proxy}" unless protocol
      @opts.proxy = url.parse @opts.proxy

    @server = http.createServer()
    @server.on 'request', @request
    @server.on 'error', (e) =>
      @emit 'error', e

  _isDownloadable: (res) ->
    res.statusCode in [200, 206] and
      res.headers['content-range']? and
      (parseInt res.headers['content-length']) >= @opts.contentLength 

  request: (clientReq, clientRes) =>
    reqOpts = url.parse clientReq.url
    reqOpts.method = clientReq.method
    reqOpts.headers = clientReq.headers
    reqOpts.agent = new http.Agent maxSockets: Infinity

    if @opts.proxy
      { hostname, protocol } = reqOpts
      reqOpts.port = @opts.proxy.port
      # hostname is preferred over host, override the two
      reqOpts.host = reqOpts.hostname = @opts.proxy.hostname
      # path now needs to contain the complete url
      reqOpts.path = reqOpts.href

    # Create new request
    request = new Request reqOpts, @opts

    # Listen to connect and determine whether to stream download or not
    request.on 'connect', (res, callback) =>
      opts = @_isDownloadable res

      headers = _.clone res.headers
      # Remove response's content-range header if the client didn't send a range header
      delete headers['content-range'] unless clientReq.headers['range']
      clientRes.writeHead res.statusCode, headers

      callback opts

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
