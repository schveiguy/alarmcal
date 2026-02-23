module alarmcal.router;

import serverino;
import std.uri : encode;

enum encodedPath(string s) = s.encode();
alias methodRoute(string path, Request.Method method) = route!(req => req.method == method && req.path == encodedPath!path);
alias getRoute(string path) = methodRoute!(path, Request.Method.Get);
alias postRoute(string path) = methodRoute!(path, Request.Method.Post);
