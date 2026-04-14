; DeciLoad 11.5kbaud Loader v1.1
; (c) 2026 Jonah Nuttgens
; Unit Interval = 208 T-states
; Baud rate = 16827baud at 3.5MHz

; Assembled length = 255 bytes

; Note use of undocumented Z80 opcode ED 70 at "detedge".
; This is coded as either "in (c)" or "in f,(c)" depending on the assembler.

	org 65280
; Enter with HL = load start address, IX = byte count (excluding checksum), interrupts disabled.
decld16	ld iy,lutbase	;Base address of the 3b/4b decode LUT. 5b/6b LUT is offset by -32 bytes, with the first and last 5 entries unused.
	xor a		;Initialise checksum to zero
	ld c,a		;C = polarity (00 or FF), B = status / pilot counter, starting from $FF
	ex af,af'
	exx
	ld bc,$FFFE	;IN port address = $FFFE
	ld hl,retpepo	;Address of self-modifying opcode
	exx
	ld a,process-jrfrom
	ld (jrfrom-1),a	;Initialise jump address to "process" routine. This will be modified to point to "decode" when sync byte is found
	call nopilot	;Jump in to the "nopilot" routine, saving the "return" address as the "edgedet" routine.

;This section is reached if we detect an edge (change of EAR signal state) during the tape input polling loop, which triggers the condition RET instruction, either RET PE or RET PO.
edgedet	dec sp		;Edge detected
	dec sp		;Decrement Stack Pointer so the return address can be reused next time
	xor e		;Flip A between $E0 and $E8, opcodes for ret po and ret pe respectively
	ld (hl),a	;Update opcode at address HL
	set 2,e		;Border green
runout	dec d
	jr nz,runout	;16T loop to count down the remaining value of D

;This section is reached at the end of each UI. If reached directly from the polling loop (D = 0), then we need an extra 5T padding to round up the loop time to a multiple of 8T.
noedge	ret nz		;5T padding
endui	exx
	cp $E8		;Test whether A (holding the conditional RET opcode) is $E0 or $E8, setting the Carry flag accordingly
	rl e		;Shift the received bit into DE'
	rl d		;If a 1 pops out the other end of the shift register, then we have captured a complete data word. Go and process it.
	jr c,process	;Displacement byte is modified at runtime to jump to either "process" or "decode"
jrfrom	exx
	out (c),e	;Update border colour. This will be black (E=$08) if no edge was detected, else the colour indicates the relative timing of the edge.
	ld de,$0408	;Reset polling loop counter D and default OUT data value E
	jp detedge	;Start next Unit Interval.

;TIMINGS:
;Define n = initial value of polling loop counter; m = value of polling loop counter when an edge was detected...
;
;From "endui" to first "detedge" = 70T
;
;If no edge is detected:
;From first execution of "detedge" to "endui" (including the 5T RET NZ padding) = (32n+10)T
;Total loop time = 1UI = (32n+80)T
;
;If an edge is detected:
;From first execution of "detedge" to "edgedet" = (32(n-m)+27)T
;From "edgedet" to "endui" = (16m+31)T
;Total from first execution of "detedge" to "endui" = (32n-16m+58)T
;Total loop time = (32n-16m+128)T, which equals 1UI when m=3.

;Theoretical "perfect" edge timing is midway between IN samples for D=4 and D=3. Time from first "detedge" to this point is 32(n-3.5) = 16T
;Centre of eye is 0.5UI either side of this = 104T away = -88T from first "detedge".

;Time from "endui" to "process" = 39T


;Next section deals with interpreting / decoding a string of bits captured from tape
process	ld a,e		;Apply polarity correction to contents of E
	xor c
	djnz pilot	;Test for B=1, indicating waiting for sync byte
sync	cp $35		;Test for sync byte
	jr z,datago	;Found sync byte - now start reading data
	inc b		;Otherwise set B back to 1	
	cp $CA		;Test for pilot byte
	jr nz,nopilot	;Neither sync nor pilot byte received. Reset pilot counter.
nextpil	ld d,2		;Pilot byte matches - capture next 8 bits
	ret nz
	ret nz		;10T padding
	jr delset
pilot	cp $CA		;Test received byte against pilot pattern $CA
	nop
	nop
	jr z,nextpil
nopilot	ld b,$FF	;Reset pilot counter
	ld a,b		;A=$FF
	xor c		;Invert polarity for next pilot byte search
	ld c,a
	add a,2
	ld d,a		;Next word captured is either 8 bits or 9 bits long, depending on polarity setting
	nop
delset	ld a,4
procpad	dec a
	jr nz,procpad	;16T delay loop. Delay = (16a-5)T
	jr bit1
datago	ld a,decode-jrfrom
	ld (jrfrom-1),a	;Change displacement in jump instruction to point to "decode" routine
	ld de,$0060	;Prepare to capture 10 bits
	jr delset

;Time from "process" to "sample1":
; Via "sync" and "nextpil" = 84+16a-5+16 = 159T (a=4)
; Via "pilot" and "nextpil" = 84+16a-5+16 = 159T (a=4)
; Via "sync" and "nopilot" = 94+16a-5+16 = 169T (a=4) *slight timing offset here, but this is a rare (error) condition anyway!
; Via "pilot" and "nopilot" = 84+16a-5+16 = 159T (a=4)
; Via "datago": 84+16a-5+16 = 159 (a=4)


;Main tape input polling loop, with repetition rate of 32T. It is placed here to put it within reach of relative jumps in and out of the routine.
retpepo	ret po		;This will be modified at runtime, alternating between ret po and ret pe
	dec d
	jr z,noedge	;If D reaches zero during this loop, then it means no data edge was detected in this Unit Interval.
detedge	in (c)		;Loop entry point.
	jp (hl)		;Loop back to retpepo


;Time from "endui" to "decode" = 39T

;Now the 8b/10b decoding routine. Will need to reset B to FF at end.
decode	bit 6,d		;Determine which decode phase we are in
	jp nz,fetch3b	;Skip to second stage of decode

;Decode stage 1 - MSBs of D will be 100000
	ld a,e		;Apply polarity correction to contents of E
	xor c
	and $0F		;Decode the 3b/4b section first
	ld (fetch3b+2),a	;Set the LUT address for the 3b decode
	ld a,e
	sra d		;Shift the LSB of D into carry
	rra		;and onwards into the MSB of A
	sra d		;D should now contain $E0
	rra		;A now contains the 6b code in the upper 6 bits
	xor c		;Apply polarity inversion. This instruction also clears the carry flag,
	rra		;so RRA will put a zero in bit7
	srl a		;but for the final shift we need to use the (slower) SRL instruction to fill bit 7 with a zero
	add a,d		;Adding $E0 is equivalent to subtracting 32, to offset the base address for the 5b/6b LUT
	ld (fetch5b+2),a	;Set the LUT address for the 5b decode
	ld de,$1E00	;Prepare to capture the first 5 bits of the next word
	ld b,2
dec1pad	djnz dec1pad	;21T padding
	jp bit1

;Decode stage 2 - D=$E0. Must not corrupt E.
fetch3b	ld a,(iy+0)	;Fetch 3b/4b LUT decode result
	cp d		;Test for error, indicated by LUT byte value = $E0
	jr z,error
	and d		;D=$E0. Set the lower 5 bits to zero, keeping only the 3b decode result in the 3 top bits
	ld b,a		;Store intermediate result
fetch5b	ld a,(iy+0)	;Fetch 5b/6b LUT decode result
	;Possible future upgrade here by adding cp $3C / jr z,nn to test for K28 control codes.
	or d		;D=$E0. Set the upper 3 bits to one, keeping only the 5b decode result in the lower 5 bits
	xor b		;Combine 3b and 5b results. The 3b value will end up inverted from the LUT contents.
	ld b,a		;Final decode result
	ex af,af'
	add a,b		;Update checksum
	ex af,af'
	ld a,ixl
	or ixh		;Test whether IX=0, and if so, then this was the final checksum byte
	jp z,exit
	ld d,$18	;Prepare to capture the last 5 bits of the next word
	ld (hl),b	;Finally, write the decoded byte to memory
	inc hl		;and increment write address ready for next byte.
	dec ix		;Decrement byte counter IX

;Timing:
;Time from "decode" to "sample1" via decode stage 1 = 159T
;Time from "decode" to "sample1" via decode stage 2 = 159T
;Total time from "endui" to "detedge" via decode = 39+159+80 = 278T
;Compared to "endui" to "detedge" directly, which takes 70T, route via decode is 208T longer, which equals 1UI

;Capture first bit of next data word. Note that E is shifted left in this process, but D is not.
bit1	exx
sample1	in a,(c)	;80T from here to "detedge"
	ld de,$0408
	add a,e		;A is expected to be either $FF or $BF. This is a quick method of setting or clearing the Carry flag accordingly.
	sbc a,a		;Set A to either $FF or $00, preserving Carry flag
	exx
	rl e		;Shift received bit into E. No need to shift D, since there is not yet any useful data to shift into it.
	exx
	and e
	xor $E8		;Construct RET PE / RET PO opcode
	ld (hl),a	;Place at "retpepo" address
	nop		;4T padding
	jr detedge

;Exit and return
exit	ex af,af'
;Arriving here via "error" jump skips the ex af,af' instruction, leaving A=$E0
error	pop hl		;Dummy pop to clear the call return address from the stack
	exx
	out (c),d	;Clear port FE, setting border black
	ret


;Now the LUT, starting from index 5 for the 5b/6b decodes (since values 0-4 are unused)
;The 3b/4b decoding table overlaps with a 32-byte offset
;Bits 7:5 are the 3b/4b decode values, inverted; bits 4:0 are the 5b/6b decode values.
;Special values: $E0 = error (all 0's or all 1's in the 4b data), and $3C = K28 (for possible future use).
	defb $17,$08,$07
	defb $00,$1B,$04,$14,$18,$0C,$1C,$3C
	defb $00,$1D,$02,$12,$1F,$0A,$1A,$0F
	defb $00,$06,$16,$10,$0E,$01,$1E,$00
lutbase	defb $E0,$1E,$61,$91,$F0,$A9,$39,$00
	defb $0F,$C5,$55,$FF,$8D,$62,$1D,$E0
	defb $3C,$03,$13,$18,$0B,$04,$1B,$00
	defb $07,$08,$17
