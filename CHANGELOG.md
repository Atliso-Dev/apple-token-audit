# Changelog

Every release is on the [releases page](https://github.com/Atliso-Dev/apple-token-audit/releases) with its zip, and on [atliso.com](https://atliso.com/tools) under Version history.

## 1.0.0 - 2026-10-18

First release. Lists the Apple MDM push certificate, every ADE enrolment token and every Apps and Books (VPP) token in Intune with expiry date, days left and the Apple ID behind each. Notes the 30-day push certificate grace period, flags personal Apple IDs and invalid VPP tokens, exports a CSV and exits 1 when anything needs renewing. Read-only.

Tested: Pester (10 tests, Graph mocked) on Windows PowerShell 5.1 and PowerShell 7; live run against a lab tenant with no Apple setup (push certificate 404, ADE and VPP empty, exit 0).

Guide: https://atliso.com/blog/intune-apple-mdm-push-certificate-expired

