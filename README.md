# Koha Interlibrary Loans ReprintsDesk backend

This backend provides the ability to create Interlibrary Loan requests using the ReprintsDesk service.

## Getting Started

This backend is only compatible with Koha 22.11+ and requires applying [bug 30719](https://bugs.koha-community.org/bugzilla3/show_bug.cgi?id=30719) if the Koha version you're using does not have this.

## Installing

* Create a directory in `Koha` called `Illbackends`, so you will end up with `Koha/Illbackends`
* Clone the repository into this directory, so you will end up with `Koha/Illbackends/koha-ill-reprintsdesk`
* Rename the `koha-ill-reprintsdesk` directory to `ReprintsDesk`
* Activate ILL by enabling the `ILLModule` system preference

## Configuration

* Mandatory configuration is done using the [ReprintsDesk API plugin](https://github.com/PTFS-Europe/koha-plugin-api-reprintsdesk).
