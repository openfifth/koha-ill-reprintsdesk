# Koha Interlibrary Loans ReprintsDesk backend

This backend provides the ability to create Interlibrary Loan requests using the ReprintsDesk service.

## Installing

* Install required dependencies: ```cpan XML::Compile XML::Smart XML::Compile:WSDL11 XML::Compile::SOAP12```
* Install the plugin by uploading the .kpz from the [releases page](https://github.com/openfifth/koha-ill-reprintsdesk/releases) and restart plack if not automated
* Activate ILL by enabling the `ILLModule` system preference

## Configuration

* Mandatory configuration is done using the plugin's configure page

## User DOCS:
1) When a ReprintsDesk request is created, its status is 'NEW'.
2) A cronjob that runs every minute picks up all 'NEW' requests and performs an availability+price check.
3) If the article is immediately available or its price is below the configured price threshold, it's put in a 'READY' status.
4) If the article is not immediately available and its price is above the configured price threshold, it's in a 'STANDBY' status.
5) A different cronjob that runs every minute picks up all 'READY' requests and places the orders with ReprintsDesk
6) For 'STANDBY' requests, staff members action is required. Once checked, staff members may click "Mark request 'READY'", which will prompt the request to be picked up by the cronjob mentioned in 5).
7) If, for any reason, a request is 'ERROR', the cause of the error is added to the staff notes (service unavailable, or a field missing). Staff members may fix this problem, if possible, and click the "Mark request 'NEW'" which will prompt the request to enter the life cycle again for a new price check, etc.