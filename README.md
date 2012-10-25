#VS-2012-WS-A1-PDTT
Start the erl shell like this: `erl -setcookie vs -name pdtt` and make
your node visible by pinging someone else on the network:
`net_adm:ping('arbr@lab25.cpt.haw-hamburg.de').`
##Aufgabenverständnis
Der Server verwaltet eine Liste von Clients, sowie eine Delivery- und Hold-Back-Queue. Die Delivery-Queue enthält die Nachrichten, die als naechstes an alle Clients verschickt werden und die Hold-Back-Queue hält die eingegangen Nachrichten in unsortierter Reihenfolge. Sobald die Hold-Back-Queue die Hälfte der Länge der Delivery-Queue erreicht hat, wird versucht, die Elemente in sortierter Reihenfolge an die Delivery-Queue anzuhängen. Sollte es nicht möglich sein, mindestes ein Element hinzuzufügen, so wird stattdessen eine Fehlernachricht an die Delivery-Queue angehängt (falls die Lücke größer als eins ist, wird dennoch nur eine Fehlernachricht erzeugt).
Nähere Details benötigten können der Aufgabenstellung auch ohne weitere Reflexion entnommen werden.
##Entwurf
Die Archtitektur für diese Aufgabe erscheint uns noch nicht allzu kompliziert und wir halten es für ausreichend den Server als einzelnes Modul zu implementieren, das nur eine `receive`-Funktion enthält, die auf die Nachrichten `getmessages`, `dropmessage` und `getmsgid` reagiert. Beim Client gehen wir ebenso vor, doch dieser reagiert nur auf Nachrichten der Form `{Nachrichteninhalt,Getall}` und `Number`.
