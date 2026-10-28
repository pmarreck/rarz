# Unknown-block reading semantics

The earlier #29 note proposed rejecting an unknown block when its skip flag
was absent. The [RAR5 format description](https://www.rarlab.com/technote.htm)
defines that flag for archive updates. It does not establish a general
validation rejection rule.

Eight controls insert a type-127 block before ENDARC in genuine RAR4 and RAR5
producer fixtures. They cross both flag values with absent/present opaque
payload data. UNRAR and rarz accept every case and correctly reach the later
ENDARC record. Clearing the flag alone therefore does not establish damage.
Eight corresponding header-CRC mutations are rejected by rarz.

No parser behavior change was needed. The persistent CLI controls preserve
readability and header integrity without adding a false rejection rule.
This does not claim verification of unknown payload semantics or implement
archive-update preservation rules; those remain separate contracts.
