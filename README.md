#VS-2012-WS-A1-PDTT
Start the erl shell like this: `erl -setcookie vs -name pdtt`

Compile everything: `c(werkzeug). c(server). c(client).`

Start the server like this: `server:start().`

Start the client like this: `client:start(NodeName)` where NodeName is the text that stands in front of every input line of the erl shell. Example:

    (pdtt@ws-95-212.HAW.1X)1> 

then set `NodeName = 'pdtt@ws-95-212.HAW.1X'.`.