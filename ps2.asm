	page    ,132
;-----------------------------Module-Header-----------------------------;
; Module Name:  PS2.ASM
;
; Windows mouse driver data and initialization routines for using the
; PS/2 mouse port.
;
; Created: 21-Aug-1987
; Author:  Mr. Mouse [mickeym], Walt Moore [waltm]
;
; Modifications:
;
; 28-Mar-1990  jimmat  Also disabled interrupts on Int 33h enable
; call from ps2_disable routine.  This has the same problem as the Int 15h
; calls documented below (in this case, it's the DOS mouse driver making
; the Int 15h calls, not the Windows driver).  What a hack for these
; 2500 XL machines!  They should fix their BIOS!
;
; 07-Feb-1990. -by- Jim Mathews [jimmat] & Amit Chatterjee [amitc]
; Across all INT 15H calls in the enable and disable procedures we will
; mask off all interrupts but for IRQ 1 & 2. This was done to fix a bug that
; occured on TANDY 2500XL machines. 
;
; On these machines the mouse port communicates with the 8042 keyboard 
; controller which is also used by HIMEM.SYS to toggle the state of the A20
; line. A command byte that is output to the 8042 and is intended for the 
; mouse port is preceeded by a special 'escape' byte (D4H) which tells the
; 8042 that the next byte is for the mouse. If an interrupt causes the DOSX
; to switch to protected mode after the escape byte has been output but before
; the actual mouse command could be output, then DOSX would program the 8042
; to enable the A20 line and make the 8042 lose the synchronization with the
; BIOS code. To take care of this problem we disble all interrupts but for
; IRQ 1 & 2 when we make INT 15H mouse related calls.
;
; Copyright (c) 1986,1987  Microsoft Corporation
;
; Exported Functions:
;       None
; Public Functions:
;       ps2_enable
;       ps2_disable
;       ps2_search
; Public Data:
;       None
; General Description:
;       This module contains the functions to find, enable, disable,
;       and process interrupts for an 8255 Bus Mouse.
;-----------------------------------------------------------------------;

	title   PS/2 Mouse Hardware Dependent Code

	.xlist
	include cmacros.inc
	include mouse.inc
	.list
.386 ; it must go here it seems

	??_out  PS2


	externNP hook_us_in             ;Hook us into our interrupt
	externNP unhook_us              ;Hook us out of our interrupt



;       (CB) Constants for VMware backdoor.
VMWARE_MAGIC    equ     564D5868h
VMWARE_PORT     equ     5658h
; commands are not hex
CMD_GETVERSION          equ     10
CMD_ABSPOINTER_DATA     equ     39
CMD_ABSPOINTER_STATUS   equ     40
CMD_ABSPOINTER_COMMAND  equ     41
ABSPOINTER_ENABLE       equ     45414552h
ABSPOINTER_RELATIVE     equ     0F5h
ABSPOINTER_ABSOLUTE     equ     53424152h

;       Subfunctions to int 15h

I15_GET_CONFIG          equ     0C0h    ;Get configuration
I15_MOUSE_SUBFUNC       equ     0C2h    ;Mouse subfunction to int 15h

PS2MSF_ENAB_DISAB       equ     0       ;  Enable/Disable subfunction
PS2MSF_RESET            equ     1       ;  Reset
PS2MSF_SET_SAMPLE       equ     2       ;  Set sample rate
PS2MSF_SET_RES          equ     3       ;  Set resolution
PS2MSF_INIT             equ     5       ;  Initialize subfunction
PS2MSF_SET_SCALING      equ     6       ;  Set scaling
PS2MSF_INSTALL_IH       equ     7       ;  Install interrupt handler

;       parameters for the subfunctions, usually passed in BH

PS2M_PACKET_SIZE        equ     3       ;Use three byte packets for mouse
PS2M_TRANS_ERROR        equ     4       ;Transmission error code
PS2M_CNTS_PER_MM        equ     3       ;3 count per mm = ~ 200 ppi
PS2M_DISABLE            equ     0       ;Disable the mouse
PS2M_ENABLE             equ     1       ;Enable the mouse
PS2M_SCALING            equ     1       ;1:1 scaling
PS2M_SAMPLING_40        equ     2       ;40 reports per second
PS2M_SAMPLING_100       equ     5       ;100 reports per second


;       PS_2 status byte definition

VMWARE_LEFT	equ	20h		; Status of left button
VMWARE_RIGHT	equ	10h		; Status of right button
VMWARE_MIDDLE	equ	08h		; Status of middle button

sBegin  Data

externB vector                          ;Vector # of mouse interrupt
externB mouse_flags                     ;Various flags as follows
externD event_proc                      ;Mouse event procedure when enabled
externD bios_proc                       ;Contents of old interrupt vector

; These used to be copied to device_int, but since we just keep the interrupt
; handler in the code segment, we move these to the data segment.

;       PS2_DATA_FLAG is where the flag indicating there is
;       valid mouse data is stored.  If this location is non-
;       zero, then the following locations contain valid data.
globalB PS2_DATA_FLAG, 0

globalW prev_x, 0
globalW prev_y, 0
globalW prev_state, 0

;-----------------------------------------------------------------------;
; state_xlate
;
;       state_xlate is used to translate the current and previous
;       button state information into the values required by
;       Windows.  It is indexed as follows:
;
;           pB2 pB1 cB2 cB1
;
;            |   |   |   |
;            |   |   |    --- 1 if button 1 is  down, 0 if button 1 is  up
;            |   |   |
;            |   |    ------- 1 if button 2 is  down, 0 if button 2 is  up
;            |   |
;            |    ----------- 1 if button 1 was down, 0 if button 1 was up
;            |
;             --------------- 1 if button 2 was down, 0 if button 2 was up
;
;       This table must be copied to the data segment along with the
;       interrupt handler.
;
;-----------------------------------------------------------------------;

page

state_xlate db 0
	;db      0                       shr 1
	db      (SF_B1_DOWN)            shr 1
	db      (SF_B2_DOWN)            shr 1
	db      (SF_B2_DOWN+SF_B1_DOWN) shr 1

	db      (SF_B1_UP)              shr 1
	db      0                       shr 1
	db      (SF_B1_UP+SF_B2_DOWN)   shr 1
	db      (SF_B2_DOWN)            shr 1

	db      (SF_B2_UP)              shr 1
	db      (SF_B1_DOWN+SF_B2_UP)   shr 1
	db      0                       shr 1
	db      (SF_B1_DOWN)            shr 1

	db      (SF_B2_UP+SF_B1_UP)     shr 1
	db      (SF_B2_UP)              shr 1
	db      (SF_B1_UP)              shr 1
	db      0                       shr 1

	.errnz  NUMBER_BUTTONS-2        ;Won't work unless a two button mouse

page

sEnd    Data


sBegin  Code
assumes cs,Code
page

;--------------------------Interrupt-Routine----------------------------;
; ps2_int - Mouse Interrupt Handler for the PS/2 Bus Mouse
;
; This is the handler for the interrupt generated by the PS/2
; mouse.  It will reside in the Data segment.
;
; Entry:
;       DS = Data
; Returns:
;       AX = status
;       BX = delta X
;       CX = delta Y
; Error Returns:
;       None
; Registers Preserved:
;       SI,DS,ES,BP
; Registers Destroyed:
;       AX,BX,CX,DX,DI,FLAGS
; Calls:
;       None
; History:
;       Fri 21-Aug-1987 11:43:42 -by-  Walt Moore [waltm] & Mr. Mouse
;       Initial version
;-----------------------------------------------------------------------;

;------------------------------Pseudo-Code------------------------------;
; {
; }
;-----------------------------------------------------------------------;

	assumes cs,Code
	assumes ds,nothing
	assumes es,nothing
	assumes ss,nothing

		public  ps2_int         ;Public for debugging
ps2_int proc    far

	; The interrupt handler only has CS set. We need to restore DS.
	push ds
	push seg bios_proc
	pop ds
	assumes ds,Data
	pushf                           ;PS/2 mouse -- get data & issue EOI
	call    bios_proc               ;  using the BIOS routines
	test    PS2_DATA_FLAG,0FFh
	jz      ps2_int_exit            ;Not a valid PS/2 mouse interrupt

	push    ax                      ;Save the world
	push    bx
	push    cx
	push    dx
	push    si
	push    di
	push    bp
	push    ds
	push    es
	mov     ax,_DATA
	mov     ds,ax
	assumes ds,Data
	assumes cs,Code

	; (old handling code removed to save space for VMware handler)

	; VMware absolute status
	; It seems we'll need to use the full 32-bit register...
	xor ebx, ebx
	mov ecx, CMD_ABSPOINTER_STATUS
	call Backdoor
	; We need at least four bytes of data.
	cmp ax, 4
	jl ps2_no_data
	; VMware absolute data
	mov ebx, 4
	mov ecx, CMD_ABSPOINTER_DATA
	call Backdoor
	; VMware will return the following in E[ABCD]X
	; EAX = flags, buttons (10h right 20h left 8h middle)
	; EBX = x (0 - FFFFh scaled)
	; ECX = y (ditto)
	; EDX = z (scroll wheel as 8-bit signed, can ignore)
	; Windows wants:
	; AX  = flags (absolute, button transitions)
	; BX  = x (0 - FFFFh scaled, we caught a break)
	; CX  = y (ditto)
	; DX  = number of buttons
	; Translate the button state.
	mov dx, ax
	xor ax, ax
	test dx, VMWARE_LEFT
	jz not_left_click
	or ax, 1h
not_left_click:
	test dx, VMWARE_RIGHT
	jz not_right_click
	or ax, 2h
not_right_click:
	; Blit the previous state as PPxx
	mov dx, prev_state
	shl dx, 2
	or ax, dx
	; Save current state for the next time
	mov dx, ax
	and dx, 3 ; mask out all bit two lowest
	mov prev_state, dx
	; XXX: Middle clicks?
	push bx ; save X pos because we need to do an indexed load
	mov bx, DataOFFSET state_xlate ; does indirect ref otherwise
	mov di, ax
	mov al, [bx + di]
	shl ax, 1 ; XXX: Why is it shifted in state_xlate?
	pop bx ; restore X pos
	; end button code
	; Only set SF_MOVEMENT if there was a difference
	xor dx, dx ; Use DX as scratch again
	cmp prev_x, bx
	jne not_same_x
	inc dx
not_same_x:
	cmp prev_y, cx
	jne not_same_y
	inc dx
not_same_y:
	cmp dx, 2
	je set_deltas
	or ax, SF_MOVEMENT
set_deltas:
	mov prev_x, bx
	mov prev_y, cx
	or ax, SF_ABSOLUTE
	; XXX: Can we add the middle button/wheel?
	mov dx, NUMBER_BUTTONS
	; ESI/EDI are used by Pen Windows, so IDK. Already zeroed.
	xor si,si
	xor di,di
	sti
	call    event_proc

ps2_no_data:
	pop     es
	pop     ds
	pop     bp
	pop     di
	pop     si
	pop     dx
	pop     cx
	pop     bx
	pop     ax

ps2_int_exit:
	pop ds
	iret

ps2_int endp
page

;--------------------------Interrupt-Routine----------------------------;
; ps2_soft_int - Mouse Interrupt Handler for the PS/2 Mouse
;
; This is the back end interrupt handler for the PS/2.  This is the
; routine that the BIOS will call when it finally passes the mouse
; event on to the installed handler.
;
; This routine just stores the passed data and sets a flag for the
; front end indicating that there is mouse data available.  This
; is required since the BIOS handler will not issue reenable mouse
; interrupts until this routine returns, which would allow interrupts
; to be missed.
;
; Entry:
;       byte ptr ss:[sp][0Ch] = status
;       byte ptr ss:[sp][0Ah] = delta X
;       byte ptr ss:[sp][08h] = delta Y
; Returns:
;       None
; Error Returns:
;       None
; Registers Preserved:
;       All
; Registers Destroyed:
;       None
; Calls:
;       None
; History:
;       Fri 21-Aug-1987 11:43:42 -by-  Walt Moore [waltm] & Mr. Mouse
;       Initial version
;-----------------------------------------------------------------------;

;------------------------------Pseudo-Code------------------------------;
; {
; }
;-----------------------------------------------------------------------;

ps2_soft_int    proc    far

;       Great care was taken to not have any labels in the following
;       code to prevent the stupid assembler from complaining (yes,
;       we have to deal with MASM ourselves).

	assumes cs,Code
	assumes ds,Data
	assumes es,nothing
	assumes ss,nothing

status  equ     byte ptr [bp+0ch]
delta_x equ     byte ptr [bp+0ah]
delta_y equ     byte ptr [bp+08h]

	push    bp
	mov     bp,sp
	push    ax
	push    ds
	mov     ax,_DATA
	mov     ds,ax
	; Don't check the actual delta, since it's invalid. Or the buttons.
	; We can recalculate in the proper interrupt handler.
	mov     PS2_DATA_FLAG,0FFh
	pop     ds
	pop     ax
	pop     bp
	ret                             ;Will restore the flags for us

ps2_soft_int    endp

page

;---------------------------Public-Routine------------------------------;
; ps2_search - Search for active PS/2 mouse port
;
; A search will be made for a mouse attached to a PS/2 via the
; keyboard/mouse port.
;
; Entry:
;       None
; Returns:
;       'C' set if found
;         AX = address of interrupt routine if interrupt vector found
;         SI = offset within the Code segment of the handler
; Error Returns:
;       'C' clear if not found
; Registers Preserved:
;       DS,BP
; Registers Destroyed:
;       AX,BX,DX,DI,SI,ES,FLAGS
; Calls:
;       int 15h
;       int 21h
;       int 11h
; History:
;       Fri 21-Aug-1987 11:43:42 -by-  Walt Moore [waltm] & Mr. Mouse
;       Initial version
;-----------------------------------------------------------------------;

;------------------------------Pseudo-Code------------------------------;
; {
; }
;-----------------------------------------------------------------------;

	assumes cs,Code
	assumes ds,Data

		public  ps2_search
ps2_search      proc    near

	; Check for the VMware backdoor.
	xor ebx, ebx
	mov ecx, CMD_GETVERSION
	call Backdoor
	cmp eax, 0FFFFFFFFh ; -1 is failure
	je ps2_cant_use_it
	cmp ebx, VMWARE_MAGIC ; EBX will be the magic, even on QEMU
	jne ps2_cant_use_it
	; Under hypervisors, always assume the 286/386 PS/2 mouse vector
	mov vector, 074h
	stc                             ;Show mouse was found
	ret

ps2_cant_use_it:
	mov     vector,-1               ;Restore to "no mouse" value

ps2_machine_not_found:
	clc                             ;'C' clear shows not found
	ret

ps2_search      endp
page

;---------------------------Private-Routine-----------------------------;
; ps2_enable - Enable PS/2 Mouse
;
; The PS/2 mouse will be initialized and the interrupt vector hooked.
;
; Entry:
;       None
; Returns:
;       None
; Error Returns:
;       None
; Registers Preserved:
;       DS,BP
; Registers Destroyed:
;       AX,BX,CX,DX,SI,DI,ES<FLAGS
; Calls:
;       hook_us_in
;       int 15h
; History:
;       Fri 21-Aug-1987 11:43:42 -by-  Walt Moore [waltm] & Mr. Mouse
;       Initial version
;-----------------------------------------------------------------------;

;------------------------------Pseudo-Code------------------------------;
; {
; }
;-----------------------------------------------------------------------;

	assumes ds,Data
	assumes es,nothing
	assumes ss,nothing

		public  ps2_enable      ;Public for debugging
ps2_enable      proc    near

	mov     cx,20 shl 8 + PS2M_TRANS_ERROR  ;# retries, error code

ps2_init:
	mov     ax,I15_MOUSE_SUBFUNC shl 8 + PS2MSF_INIT
	mov     bh,PS2M_PACKET_SIZE
	call    IssueInt15              ;INT 15H with interrupts disabled
	jnc     ps2_reset               ;Successful
	cmp     ah,cl                   ;Transmission error? 
	je      @f
	jmp     ps2_enable_abort        ;  No, quit
@@:
	dec     ch
	jnz     ps2_init                ;Try again if more retries
	jmp     ps2_enable_abort  ;Quit if out of retries

ps2_reset:
	mov     ax,I15_MOUSE_SUBFUNC shl 8 + PS2MSF_RESET
	call    IssueInt15              ;INT 15H with interrupts disabled
	jnc     ps2_set_res             ;Successful
	cmp     ah,cl                   ;Transmission error?
	jne     ps2_enable_abort        ;  No, quit
	dec     ch
	jnz     ps2_reset               ;Try again if more retries
	jmp     ps2_enable_abort  ;Quit if out of retries

ps2_set_res:
	mov     ax,I15_MOUSE_SUBFUNC shl 8 + PS2MSF_SET_RES
	mov     bh,PS2M_CNTS_PER_MM
	call    IssueInt15              ;INT 15H with interrupts disabled
	jnc     ps2_install_ih          ;Successful
	cmp     ah,cl                   ;Transmission error?
	jne     ps2_enable_abort        ;  No, quit
	dec     ch
	jnz     ps2_set_res             ;Try again if more retries
	jmp     ps2_enable_abort  ;Quit if out of retries

ps2_install_ih:
	mov     ax,I15_MOUSE_SUBFUNC shl 8 + PS2MSF_INSTALL_IH
	push    seg ps2_soft_int         ;ES:BX is software int handler address
	pop     es
	assumes es,nothing
	mov     bx,CodeOFFSET ps2_soft_int
	call    IssueInt15              ;INT 15H with interrupts disabled
	jnc     ps2_scaling             ;Successful
	cmp     ah,cl                   ;Transmission error?
	jne     ps2_enable_abort        ;  No, quit
	dec     ch
	jnz     ps2_install_ih          ;Try again if more retries
	jmp     ps2_enable_abort  ;Quit if out of retries

ps2_scaling:
	mov     ax,I15_MOUSE_SUBFUNC shl 8 + PS2MSF_SET_SCALING
	mov     bh,PS2M_SCALING
	call    IssueInt15              ;INT 15H with interrupts disabled
	jnc     ps2_samples             ;Successful
	cmp     ah,cl                   ;Transmission error?
	jne     ps2_enable_abort        ;  No, quit
	dec     ch
	jnz     ps2_scaling             ;Try again if more retries
	jmp     ps2_enable_abort  ;Quit if out of retries

ps2_samples:
	mov     ax,I15_MOUSE_SUBFUNC shl 8 + PS2MSF_SET_SAMPLE
	mov     bh,PS2M_SAMPLING_40
	call    IssueInt15              ;INT 15H with interrupts disabled
	jnc     ps2_enabling            ;Successful
	cmp     ah,cl                   ;Transmission error?
	jne     ps2_enable_abort        ;  No, quit
	dec     ch
	jnz     ps2_samples             ;Try again if more retries
	jmp     ps2_enable_abort  ;Quit if out of retries

ps2_enabling:
	mov     ax,I15_MOUSE_SUBFUNC shl 8 + PS2MSF_ENAB_DISAB
	mov     bh,PS2M_ENABLE
	call    IssueInt15              ;INT 15H with interrupts disabled
	jnc     ps2_hook_us_in          ;Successful
	cmp     ah,cl                   ;Transmission error?
	jne     ps2_enable_abort        ;  No, quit
	dec     ch
	jnz     ps2_enabling            ;Try again if more retries
	jmp     ps2_enable_abort  ;Quit if out of retries

ps2_hook_us_in:
	call    hook_us_in              ;Hook our vector.  Won't alter IRQ mask

vmware_enable_absolute:
	; We need to do this *after* successfully setting up our hook.
	; I don't know if these can fail, but OSDev Wiki doesn't check,
	; and we do check if we're on something VMware-shaped before...
	mov ebx, ABSPOINTER_ENABLE
	mov ecx, CMD_ABSPOINTER_COMMAND
	call Backdoor

	; Status
	mov ebx, 0
	mov ecx, CMD_ABSPOINTER_STATUS
	call Backdoor

	; Read data 1
	mov ebx, 1
	mov ecx, CMD_ABSPOINTER_DATA
	call Backdoor

	; Enable absolute
	mov ebx, ABSPOINTER_ABSOLUTE
	mov ecx, CMD_ABSPOINTER_COMMAND
	call Backdoor

ps2_enable_abort:
	ret

ps2_enable      endp
page

;---------------------------Private-Routine-----------------------------;
; ps2_disable - Disable PS/2 Mouse
;
; The interrupt vector will be restored, and an enable call made
; to any Int 33h mouse driver.
;
; Entry:
;       None
; Returns:
;       None
; Error Returns:
;       None
; Registers Preserved:
;       DS,BP
; Registers Destroyed:
;       AX,BX,CX,DX,SI,DI,ES,FLAGS
; Calls:
;       int 15h
;       int MOUSE_SYS_VECT
; History:
;       Fri 21-Aug-1987 11:43:42 -by-  Walt Moore [waltm] & Mr. Mouse
;       Initial version
;-----------------------------------------------------------------------;

;------------------------------Pseudo-Code------------------------------;
; {
; }
;-----------------------------------------------------------------------;

	assumes ds,Data
	assumes es,nothing
	assumes ss,nothing

		public  ps2_disable     ;Public for debugging
ps2_disable     proc    near

	mov     ax,I15_MOUSE_SUBFUNC shl 8 + PS2MSF_ENAB_DISAB
	mov     bh,PS2M_DISABLE
	call    IssueInt15              ;INT 15H with interrupts disabled

	call    unhook_us

;       Restore any possible Int 33h mouse

	test    mouse_flags,MF_INT33H
	jz      ps2_disable_exit        ;No int 33h mouse

	mov     ax,I15_MOUSE_SUBFUNC shl 8 + PS2MSF_SET_SAMPLE
	mov     bh,PS2M_SAMPLING_100
	call    IssueInt15              ;INT 15H with interrupts disabled

	mov     ax,INT33H_ENABLE        ;Enable old mouse driver if it's
	call    IssueInt33              ;  there

ps2_disable_exit:
	; (CB) Put the mouse back to relative on disable?

	; Enable relative
	mov ebx, ABSPOINTER_RELATIVE
	mov ecx, CMD_ABSPOINTER_COMMAND
	call Backdoor

	ret

ps2_disable     endp


;----------------------------------------------------------------------------;
; IssueInt15:                                                                ;
;                                                                            ;
; Does an INT 15H with all interrupts but for IRQ 1 & 2 disabled at the PIC. ;
; (please read the modification history list at the begining of the file     ;
;  for more information on this.)                                            ;
;                                                                            ;
; Note: This routine assumes SI is not being passed to/from the interrupt    ;
;       handler!                                                             ;
;----------------------------------------------------------------------------;

IssueInt15 proc near

	push    si                      ;save, used as work reg
	call    DisableInts
	push    si                      ;save old mask
	int     15h
	pop     si                      ;get old mask
	call    EnableInts              ;  and restore
	pop     si
	ret

IssueInt15 endp

;------------------------------------------------------------------------
; IssueInt33:
;
; Issue an Int 33h instruction with all interrupts except IRQ 1 & 2 masked
; off in the master PIC.  See IssueInt15 & modification history for more
; information.
;
; Note: This routine assumes SI is not being passed to/from the interrupt
;       handler!
;------------------------------------------------------------------------

IssueInt33 proc near

	push    si                      ;save entry SI
	call    DisableInts             ;disable ints, old mask retruned in SI
	push    si                      ;save old mask
	int     MOUSE_SYS_VEC
	pop     si                      ;get old mask
	call    EnableInts              ;  and restore
	pop     si
	ret

IssueInt33 endp

;------------------------------------------------------------------------

DisableInts proc near

	push    ax
	in      al,21h                  ;get the current interrupt mask
	mov     si,ax                   ;  and return it in SI
	or      al,11111001b            ;mask off all but IRQ 1 & 2
	jmp     short $+2
	jmp     short $+2
	out     21h,al
	pop     ax
	ret

DisableInts endp

EnableInts proc near

	push    ax                      ;restore PIC mask using value in SI
	mov     ax,si
	out     21h,al
	pop     ax
	ret

EnableInts endp

; VMware hypercall
; Takes EBX and ECX as arguments. ESI and EDI are not used in this variant.
; Clobbers EAX and EDX in input, can return in all four registers.
Backdoor proc near

	mov eax, VMWARE_MAGIC
	mov dx, VMWARE_PORT
	in eax, dx
	ret

Backdoor endp

;----------------------------------------------------------------------------;
sEnd    Code
end
