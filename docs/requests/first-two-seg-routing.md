just use first : of the key to do prefix routing is not enough, because all keys have the same prefix "tp", use first and second of ":" for key prefix
  routing. Currently we have these key prefixes:
- tg:caveat
- tg:caveat_context
- tg:g2m
- tg:m2g
- tg:r2g
- tg:uint32id
and additionally create a "others" subject to receive all other msgs that are not being routed to above subjects. Make sure naming of subjects and consumer name are valid
