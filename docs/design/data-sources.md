# Free data source register (D-034, D-035)

Checked 2026-11-14 from the providers' own pages. This is a reading of their
terms, not legal advice: the bank's legal team must confirm before production
or external demonstration. Every source used by Veridian needs an entry here
and an approved `DataSource` record (spec 10).

| Source | Data | Terms | Automated use / reuse | Attribution | Access | Status |
|---|---|---|---|---|---|---|
| New York Fed | SOFR (and other reference rates) | https://www.newyorkfed.org/privacy/termsofuse (6/9/2023), section "Use Restrictions > Reference Rates" | Manual or automated access allowed; download, store, use, copy and distribute; no non-commercial limit found; redistribution must carry the same terms. SOFR uses DTCC Solutions data (disclosed). | Required notice that the data "is subject to the Terms of Use posted at newyorkfed.org" plus no-liability wording; products named after SOFR must say they are not affiliated with the New York Fed. | Markets Data API (https://markets.newyorkfed.org/static/docs/markets-api.html, endpoints unverified); Excel history. Published ~08:00 ET; revisions possible later the same day. | usable |
| ECB | €STR | https://www.ecb.europa.eu/home/disclaimer/html/index.en.html | "The ECB does not charge for the €STR or license its use." Free reuse with source cited and modifications stated (from summary). | Cite ECB as source. | ECB Data Portal (terms unverified: portal returned 503). Each TARGET2 business day. | usable, portal access to confirm |
| ECB | EUR FX reference rates | same | Free reuse with citation (from summary). | Cite ECB; rates are for information only. | `/stats/eurofxref/eurofxref-daily.xml`, `-hist.zip`, `-sdmx.xml`; ~16:00 CET each TARGET working day. | usable |
| Bank of England | SONIA | https://www.bankofengland.co.uk/legal (06 Nov 2026) | Bank of England Database data under the UK Open Government Licence v3.0. | Required statement beginning "SONIA and/or SONIA Compounded Index data licensed under the Open Government Licence v3.0" (copy in full from the legal page). | Interactive Statistical Database CSV; by 10:00 the next business day. No API. | usable |
| Bank of England | Yield curves (incl. OIS spot curves) | same | Built from Bloomberg and Tradeweb data; OGL coverage unverified; general clause is internal, non-commercial use. | n/a | ZIP / Excel archives only, no API. | **do not use without written permission** |
| HKMA | HONIA | http://www.hkma.gov.hk/eng/other-information/terms-and-conditions.shtml (26 Aug 2019) | Website data: non-commercial, unmodified, attributed. API: commercial or non-commercial use allowed under the same conditions; HKMA may revoke. | Attribute to HKMA; reproduce without modification. | HKMA Open API; HONIA endpoint **not found** (only overnight HIBOR seen). | to verify (HONIA availability) |
| US Treasury | Par yield curve | unverified (page returned 404) | unverified | unverified | unverified | to verify |
| GLEIF | Legal entity identifiers, level 1 (who is who) and level 2 (who owns whom) reference data, for counterparties, issuers and group structure (spec 16) | https://www.gleif.org/en/meta/lei-data-terms-of-use/ (checked 2026-11-14) | "The data available through the Access Service are provided under the CC0 licence" (from a summary of a truncated page: verify against the full text). Bulk download of all or part of the LEIs allowed; technical restrictions must not be circumvented. | None required; must not imply GLEIF provides data or services other than the original LEI data. | Golden copy and delta files three times a day (02:00, 10:00, 18:00 UTC), https://www.gleif.org/en/lei-data/gleif-golden-copy; API (rate limits unverified). No ratings or financial data. | usable, licence wording to confirm |
| ESMA | FIRDS financial instrument reference data (bond static data candidate, spec 16) | https://registers.esma.europa.eu/publication/legalNoticePage and https://www.esma.europa.eu/legal-notice (checked 2026-11-14) | "Reproduction of all information on this site (REGISTERS information) is authorised except as otherwise stated, provided the source is acknowledged." Commercial use, automated and bulk download not addressed. ESMA accepts no liability. | Acknowledge ESMA as source; state when material is transformed; must not imply ESMA endorsement. | FIRDS file list and field schema not readable (register search needs a captcha; FIRDS page 404): whether maturity, coupon, currency and issuer LEI are published is **unconfirmed**. | to verify (bulk access and fields) |

Consequences:
- Synthetic OIS par quotes (seeded, data class `synthetic`) replace published
  central-bank curves until permission exists (revises the answer to the
  spec 08 question on calibrating to published curves).
- Wherever results built on public data are shown, the attribution and notice
  texts of every source used must be shown with them.
- HKD: if HONIA cannot be sourced freely, HKD uses synthetic fixings in v1.
