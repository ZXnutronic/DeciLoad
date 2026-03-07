; DeciLoad 12.8kbaud Loader v1.1
; (c) 2026 Jonah Nuttgens
; Unit Interval = 272 T-states
; Baud rate = 12868baud at 3.5MHz

; Assembled length = 264 bytes

; Note use of undocumented Z80 opcode ED 70 at "detedge".
; This is coded as either "in (c)" or "in f,(c)" depending on the assembler.

	org 65272
; Enter with HL = load start address, BC = byte count (excluding checksum), interrupts disabled.
decld12	ld iy,lutbase	;Base address of the 3b/4b decode LUT. 5b/6b LUT is offset by -32 bytes, with the first and last 5 entries unused.
	xor a		;Initialise checksum to zero
	ld ixh,a	;IXH = polarity (00 or FF), IXL = status / pilot counter, starting from $FF
	ex af,af'
	exx
	ld bc,$FFFE	;IN port address = $FFFE
	ld hl,retpepo	;Address of self-modifying opcode
	exx
	ld a,$1D
	ld (eborder),a	;Initialise "eborder" opcode to "dec e"
	ld a,process-jrfrom
	ld (jrfrom-1),a	;Initialise jump address to "process" routine. This will be modified to point to "decode" when sync byte is found
	inc bc
	call nopilot	;Jump in to the "nopilot" routine, saving the "return" address as the "edgedet" routine.

;This section is reached if we detect an edge (change of EAR signal state) during the tape input polling loop, which triggers the condition RET instruction, either RET PE or RET PO.
edgedet	dec sp		;Edge detected
	dec sp		;Decrement Stack Pointer so the return address can be reused next time
	xor e		;Flip A between $E0 and $E8, opcodes for ret po and ret pe respectively
	ld (hl),a	;Update opcode at address HL
	dec d		;First step of runout timer
	jr z,endui
	ret z		;5T padding (condition always false)
runout	inc e
eborder	nop		;This instruction initialised at "dec e" - modified at runtime to "nop" to start modifying the border colour.
	dec d
	jr nz,runout	;24T loop to count down the remaining value of D

;This section is reached at the end of each UI. If reached directly from the polling loop (D = 0), then we need an extra 5T padding to round up the loop time to a multiple of 8T.
noedge	ret nz		;5T padding
endui	exx
	cp $E8		;Test whether A (holding the conditional RET opcode) is $E0 or $E8, setting the Carry flag accordingly
	rl e		;Shift the received bit into DE'
	rl d		;If a 1 pops out the other end of the shift register, then we have captured a complete data word. Go and process it.
	jr c,decode	;Displacement byte is modified at runtime to jump to either "process" or "decode"
jrfrom	exx
	out (c),e	;Update border colour. This will be black (E=$08) if no edge was detected, else the colour indicates the relative timing of the edge.
	ld de,$0608	;Reset polling loop counter D and default OUT data value E
	jp detedge	;Start next Unit Interval.

;Main tape input polling loop, with repetition rate of 32T
retpepo	ret po		;This will be modified at runtime, alternating between ret po and ret pe
	dec d
	jr z,noedge	;If D reaches zero during this loop, then it means no data edge was detected in this Unit Interval.
detedge	in (c)		;Loop entry point.
	jp (hl)		;Loop back to retpepo


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
;From "edgedet" to "endui" = (24m+15)T
;Total from first execution of "detedge" to "endui" = (32n-8m+42)T
;Total loop time = (32n-8m+112)T, which equals 1UI when m=4.

;Theoretical "perfect" edge timing is midway between IN samples for D=5 and D=4. Time from first "detedge" to this point is 32(n-4.5) = 48T
;Centre of eye is 0.5UI either side of this = 136T away = -88T from first "detedge".

;Time from "endui" to either "process" or "decode" = 39T


;Next section deals with interpreting / decoding a string of bits captured from tape
; Modifed to replace B/C with IXL/IXH and remove test for decode
process	inc bc		;Compensate for dec bc in "bit1" routine if we have not yet started decoding data.
	ld a,e
	xor ixh		;Apply polarity inversion to received byte
	ret c		;5T padding (condition is always false)
	dec ixl		;Test for IXL=1, indicating waiting for sync byte
	jr nz, pilot
sync	cp $35		;Test for sync byte
	jr z,datago	;Found sync byte - now start reading data
	inc ixl		;Otherwise set IXL back to 1
testpil	cp $CA		;Test for pilot byte
	jr nz,nopilot	;Neither sync nor pilot byte received. Reset pilot counter.
nextpil	ld d,2		;Pilot byte matches - capture next 8 bits
	ld a,7
	jr procpad
pilot	ret z		;5T padding (condition is always false)
	jr testpil
nopilot	ld a,$FF
	ld ixl,a	;Reset pilot counter
	xor ixh		;Invert polarity for next pilot byte search
	ld ixh,a
	add a,2
	ld d,a		;Next word captured is either 8 bits or 9 bits long, depending on polarity setting
	ld a,5
	nop
procpad	dec a
	jr nz,procpad	;16T delay loop. Delay = (16a-5)T
	jr bit1
datago	xor a
	ld (eborder),a	;Change "eborder" instruction to "nop", to start showing border colours
	ld a,decode-jrfrom
	ld (jrfrom-1),a	;Change displacement in jump instruction to point to "decode" routine
	ld a,6
gopad	dec a
	jr nz,gopad	;16T delay loop. Delay = (16a-5)T
	ret nz		;5T padding (condition is always false)
	jr datago2

;Time from "process" to "sample1":
; Via "nextpil" = 100+16a-5+16 = 223T (a=7)
; Via "nopilot" = 132+16a-5+16 = 223T (a=5)
; Via "datago": 101+16a-5+31 = 223T (a=6)


;Time from "endui" to "decode" = 39T

;Now the 8b/10b decoding routine
decode	ld a,e		;Invert contents of E first. D will be dealt with later
	xor ixh
	and $0F		;Decode the 3b/4b section first
	ld (fetch3b+2),a	;Set the LUT address for the 3b decode
	ld a,e
	sra d		;Shift the LSB of D into carry
	rra		;and onwards into the MSB of A
	sra d		;D should now contain $E0
	rra		;A now contains the 6b code in the upper 6 bits
	xor ixh		;Apply polarity inversion. This instruction also clears the carry flag,
	rra		;so RRA will put a zero in bit7
	srl a		;but for the final shift we need to use the (slower) SRL instruction to fill bit 7 with a zero
	add a,d		;Adding $E0 is equivalent to subtracting 32, to offset the base address for the 5b/6b LUT
	ld (fetch5b+2),a	;Set the LUT address for the 5b decode
fetch3b	ld a,(iy+0)	;Fetch 3b/4b LUT decode result
	cp $E0		;Test for error, indicated by LUT byte value = $E0. Note use of literal $E0 rather than register D, to add 3T.
	jr z,error
	and d		;D=$E0. Set the lower 5 bits to zero, keeping only the 3b decode result in the 3 top bits
	ld e,a		;Store intermediate result
fetch5b	ld a,(iy+0)	;Fetch 5b/6b LUT decode result
	;Possible future upgrade here by adding cp $3C / jr z,nn to test for K28 control codes.
	or d		;D=$E0. Set the upper 3 bits to one, keeping only the 5b decode result in the lower 5 bits
	xor e		;Combine 3b and 5b results. The 3b value will end up inverted from the LUT contents.
	ld d,a		;Final decode result
	ex af,af'
	add a,d		;Update checksum
	ex af,af'
	ld a,c
	or b		;Test whether BC=0, and if so, then this was the final checksum byte
	jr z,exit	;dec bc instruction relocated into "bit1" routine
	ld (hl),d	;Finally, write the decoded byte to memory
	inc hl		;and increment write address ready for next byte.
datago2	ld de,$0060	;Prepare to capture 10 bits

;Timing:
;Time from "decode" to "datago2" = 209T
;Time from "datago2" to "sample1" = 14T
;Time from "decode" to "sample1" = 223T
;Total time from "endui" to "detedge" via decode = 39+223+80 = 342T
;Compared to "endui" to "detedge" directly, which takes 70T, route via decode is 272T longer, which equals 1UI

;Capture first bit of next data word. Note that E is shifted left in this process, but D is not.
bit1	exx
sample1	in a,(c)	;80T from here to "detedge"
	ld de,$0608
	add a,e		;A is expected to be either $FF or $BF. This is a quick method of setting or clearing the Carry flag accordingly.
	sbc a,a		;Set A to either $FF or $00, preserving Carry flag
	exx
	rl e		;Shift received bit into E. No need to shift D, since there is not yet any useful data to shift into it.
	dec bc		;Decrement byte counter BC
	exx
	and e
	xor $E8		;Construct RET PE / RET PO opcode
	ld (hl),a	;Place at "retpepo" address
	jp detedge

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
