#VS-2012-WS-A1-PDTT
Start the erl shell: `erl -setcookie vs -name pdtt`

Compile everything: `c(werkzeug). c(server). c(client).`

Start the server: `server:start().`

Start the client: `client:start(NodeName)` where *NodeName* is the text that stands in front of every input line of the erl shell. Example:

    (pdtt@ws-95-212.HAW.1X)1> 

then set `NodeName = 'pdtt@ws-95-212.HAW.1X'.`.


Complete example:

    $ erl -setcookie vs -name pdtt
    (pdtt@ws-95-212.HAW.1X)1> c(werkzeug). c(server). c(client).
    (pdtt@ws-95-212.HAW.1X)2> server:start(). client:start('pdtt@ws-95-212.HAW.1X').
