# Bugs Found in itch_field_extract.sv

## Bug: order_ref

- **Test**: test_add_order_buy
- **Symptom**: field 'order_ref': DUT=0xF022334455667788, spec=0x1122334455667788
- **Root cause**: Line 54 of itch_field_extract.sv uses byte index 10 instead of 11 for the MSB of order_ref_comb. The concatenation extracts bytes [10,12..18] but the ITCH 5.0 spec requires bytes [11,12..18]. Byte 10 is the last byte of the 6-byte timestamp field, so the MSB of order_ref is corrupted with timestamp data.

## Bug: fields_valid

- **Test**: test_sync_reset
- **Symptom**: fields_valid not cleared by reset: expected 0, got 1
- **Root cause**: fields_valid is missing from the synchronous reset block (lines 92-97 of itch_field_extract.sv). While message_type, order_ref, side, price, and stock are all reset to 0, fields_valid is omitted. It retains its previous value during reset instead of clearing to 0 as the spec requires.

