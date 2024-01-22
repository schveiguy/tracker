# Simple time tracker app

I'm going to be using this to track hours spent on projects for clients. It's a web page so it's accessible from any device.

I currently use a 3rd party app, where I had to build extra structure around everything.

Supports multiple clients, multiple projects per client.

## How to use

Run this server on any system (should build for Windows/Linux/Mac). Then connect using the 8080 port.

The intent is not to just use this as an off-the-shelf app, but to customize it. Especially the look and feel. I have no intention of making it really pretty, basic bootstrap is enough for me. And I don't intend to make some kind of in-app editor for the invoice template, you have to customize that yourself.

It should be usable from any device (especially mobile).

## BIG WARNING

There is no security on this. No login, no password, etc. Don't put this on an internet-facing port. The default binding address is localhost for a reason.

I do want to add authentication, but I doubt it will ever get HTTPS (unless handy adds it).

## TODO

* Authentication
* Export per client/project
* Export based on regular intervals
* Statistics with regards to time or percentage targets
* Possible web page to print to pdf invoicing.
* Saving of invoices and payment received date.
