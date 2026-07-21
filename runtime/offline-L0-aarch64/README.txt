offline-L0-aarch64
==================

1. Copy this entire directory to the Debian 12 aarch64 host as:
     /opt/mdv-offline-L0-aarch64
   (or set MDV_OFFLINE_BASE_URL when packing, and match that path)

2. Install into an empty install root (example):

     sudo install -d -m 0755 /opt/mdv-p1-acceptance-aarch64-offline
     sudo cp mdv-installer /opt/mdv-p1-acceptance-aarch64-offline/
     sudo cp mdv.config.yaml /opt/mdv-p1-acceptance-aarch64-offline/
     cd /opt/mdv-p1-acceptance-aarch64-offline
     sudo ./mdv-installer install

   Default baseURL in mdv.config.yaml:
     file:///opt/mdv-offline-L0-aarch64/runtime

3. Intranet alternative: upload runtime/ to Nexus and change baseURL to HTTPS/HTTP.

OpenObserve / LibreOffice are intentionally omitted (L1/L2).
