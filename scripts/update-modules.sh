━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Database: staging-server
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Modules: eoc_base,eoc_signals
  Action:  update

    2026-04-04 06:51:50,888 34 INFO ? odoo: Odoo version 18.0-20260324
    2026-04-04 06:51:50,889 34 INFO ? odoo: Using configuration file at /etc/odoo/odoo.conf
    2026-04-04 06:51:50,889 34 INFO ? odoo: addons paths: ['/usr/lib/python3/dist-packages/odoo/addons', '/var/lib/odoo/.local/share/Odoo/addons/18.0', '/mnt/extra-addons']
    2026-04-04 06:51:50,889 34 INFO ? odoo: database: default@default:default
    2026-04-04 06:51:50,890 34 INFO ? odoo.sql_db: Connection to the database failed

  ✗ staging-server had errors (check log)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Database: testing-server
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Modules: eoc_base,eoc_signals
  Action:  update

    2026-04-04 06:51:52,283 44 INFO ? odoo: Odoo version 18.0-20260324
    2026-04-04 06:51:52,283 44 INFO ? odoo: Using configuration file at /etc/odoo/odoo.conf
    2026-04-04 06:51:52,284 44 INFO ? odoo: addons paths: ['/usr/lib/python3/dist-packages/odoo/addons', '/var/lib/odoo/.local/share/Odoo/addons/18.0', '/mnt/extra-addons']
    2026-04-04 06:51:52,284 44 INFO ? odoo: database: default@default:default
    2026-04-04 06:51:52,285 44 INFO ? odoo.sql_db: Connection to the database failed

  ✗ testing-server had errors (check log)

=========================================
✓ Update complete
  Databases with errors: staging-server testing-server

Full log: /root/ephem-deploy/logs/update_20260404_065138.log
=========================================

Restarting Odoo...
[+] restart 0/1
 ⠇ Container ephem-app Restarting                                                                                                                       1.8s
✓ Done.

root@testing-ubuntu:~/ephem-deploy/scripts#
