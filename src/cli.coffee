http = require 'http'

program = require 'commander'
Logger = require 'tmpl-log'

Proxy = require './proxy'

logr = new Logger

program
  .version('0.1.1')

program
  .command('start')
  .option('-p, --port <p>', 'port on which to listen', Number, 8080)
  .option('-H, --host <h>', 'host on which to start the proxy', String, 'localhost')
  .option('-t, --threads <t>', 'max concurrent threads', Number, 12)
  .option('-s, --partSize <p>', 'thread part size', Number, 1024 * 1024 * 2)
  .option('-l, --contentLength <l>', 'min content length for threaded downloading', Number, 1024 * 1024 * 4)
  .action (args..., { port, host, threads, partSize, contentLength }) ->
    proxy = new Proxy { threads, partSize, contentLength }
    proxy.on 'error', (e) ->
      if e.syscall is 'listen'
        switch e.code
          when 'EADDRNOTAVAIL' then logr.log "<underline><red>Error:</></> address or port not available (<bold>http://<underline>#{host}</>:#{port}</>)"
          when 'EACCES' then logr.log "<underline><red>Error:</></> reserved address or port (<bold>http://<underline>#{host}</>:#{port}</>)"
      throw e
    proxy.listen port, host, ->
      logr.log """
      Proxy started on <bold>http://<underline>#{host}</>:#{port}</>. Press CTRL+C to stop it.
      """

program.parse process.argv
