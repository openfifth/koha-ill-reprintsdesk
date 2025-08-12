# Koha Interlibrary Loans ReprintsDesk backend

This backend provides the ability to create Interlibrary Loan requests using the ReprintsDesk service.

## Installing

* Install required dependencies: ```cpan XML::Compile XML::Smart XML::Compile:WSDL11 XML::Compile::SOAP12```
* Install the plugin by uploading the .kpz from the [releases page](https://github.com/openfifth/koha-ill-reprintsdesk/releases) and restart plack if not automated
* Activate ILL by enabling the `ILLModule` system preference

## Configuration

* Mandatory configuration is done using the plugin's configure page
