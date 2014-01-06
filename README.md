catalyst-proxy
==============
A proxy that silently accelerates requests via multipart downloading. Officially the best thing ever.

`catalyst-proxy` establishes multiples connections to download a single resource from a web server, potentially increasing the download speed.

Only supports "streaming" acceleration for now: resources are cut into parts of equal length (`--partSize` CLI option) that are downloaded concurrently (`--threads` CLI option) and served sequentially. This behavior differs from most download managers and allows to consume the resource while downloading it.

Use-cases
---------
  * Speed up video streaming websites, such as YouTube.
  * Speed up software and game downloaders/installers.
  * Speed up everything.

Installation
------------
You need to have Node.JS >= 0.10.0 installed on your system.
```
$ npm install -g catalyst-proxy
```

To update:
```
$ npm update -g catalyst-proxy
```

Usage
-----
```$ catalyst start``` to boot up the proxy. Simply add the printed address and port as an HTTP proxy in your system settings and you're set.

```$ catalyst start -h``` to list all available options.

Configuration
-------------
`--partSize`, `--threads` and `--contentLength` are the three CLI options you should be tweaking.

  * `partSize` specifies the size of each thread part. For example, if set to `1048576`, it will cut the resource into parts of `1 megabyte = 1048576 bytes` each. For video streaming, you should try to set this as low as is reasonable.
  * `threads` specifies the maximum amount of concurrent threads. For example, if set to `12`, it will launch as many as `12` concurrent threads, each downloading a resource part of size `partSize`. Note that download speed will be balanced between threads.
  * `contentLength` specifies the minimum size of a resource for `catalyst` to try to download it using threaded downloading.
