option casemap:none

extrn ExitProcess : proc
extrn GetStdHandle : proc
extrn GetConsoleMode : proc
extrn SetConsoleMode : proc
extrn ReadConsoleInputA : proc
extrn WriteConsoleA : proc
extrn SetConsoleCursorPosition : proc
extrn GetTickCount : proc

includelib kernel32.lib

GRID_SIZE equ 16
ROW_STRIDE equ 18
GRID_BUF_SIZE equ (GRID_SIZE * ROW_STRIDE)
STATUS_Y equ GRID_SIZE
MAX_IDX equ (GRID_SIZE - 1)
MONSTER_COUNT equ 6

STD_INPUT_HANDLE equ -10
STD_OUTPUT_HANDLE equ -11
ENABLE_LINE_INPUT equ 2
ENABLE_ECHO_INPUT equ 4
KEY_EVENT equ 1

LINE_TEXT_LEN equ 56
LINE_LEN equ (LINE_TEXT_LEN + 2)

POS_OFFSET MACRO x, y
    movzx eax, byte ptr [y]
    imul eax, ROW_STRIDE
    movzx ecx, byte ptr [x]
    add eax, ecx
ENDM

PLACE_CHAR MACRO x, y, ch
    POS_OFFSET x, y
    mov byte ptr [r11 + rax], ch
ENDM

CHECK_HIT MACRO targetX, targetY, missLabel
    mov al, [playerX]
    cmp al, [targetX]
    jne missLabel
    mov al, [playerY]
    cmp al, [targetY]
    jne missLabel
ENDM

KEY_EVENT_RECORD STRUCT
    bKeyDown DWORD ?
    wRepeatCount WORD ?
    wVirtualKeyCode WORD ?
    wVirtualScanCode WORD ?
    uChar WORD ?
    dwControlKeyState DWORD ?
KEY_EVENT_RECORD ENDS

INPUT_RECORD STRUCT
    EventType WORD ?
    Padding WORD ?
    KeyEvent KEY_EVENT_RECORD <>
INPUT_RECORD ENDS

.data
hIn dq 0
hOut dq 0
inMode dd 0
numRead dd 0
bytesWritten dd 0
inputRec INPUT_RECORD <>

playerX db 1
playerY db 1
monstersX db 14, 1, 14, 8, 1, 14
monstersY db 14, 14, 1, 14, 8, 8
monDir db 0, 1, 2, 3, 0, 1
foodX db 8
foodY db 8

keyTable db 'w','a','s','d'
dxTable db 0, -1, 0, 1
dyTable db -1, 0, 1, 0

gridTemplate label byte
REPT GRID_SIZE
    db "----------------", 13, 10
ENDM

gridBuffer db GRID_BUF_SIZE dup(0)

statusLine label byte
    db "WASD move. Eat F. Avoid M. Q: quit."
    db (LINE_TEXT_LEN - ($-statusLine)) dup(' ')
    db 13, 10

winLine label byte
    db "YOU WIN! Press any key to exit."
    db (LINE_TEXT_LEN - ($-winLine)) dup(' ')
    db 13, 10

loseLine label byte
    db "GAME OVER! Press any key to exit."
    db (LINE_TEXT_LEN - ($-loseLine)) dup(' ')
    db 13, 10

.code

DrawBoard proc
    ; 그리드 버퍼를 만들고 상태 라인과 함께 출력함
    push rsi
    push rdi
    sub rsp, 28h
    mov [rsp], rcx

    lea rsi, gridTemplate
    lea rdi, gridBuffer
    mov ecx, GRID_BUF_SIZE
    rep movsb

    lea r11, gridBuffer
    PLACE_CHAR foodX, foodY, 'F'
    lea rsi, monstersX
    lea rdi, monstersY
    xor r8d, r8d
draw_monsters:
    movzx eax, byte ptr [rdi+r8]
    imul eax, ROW_STRIDE
    movzx ecx, byte ptr [rsi+r8]
    add eax, ecx
    mov byte ptr [r11+rax], 'M'
    inc r8d
    cmp r8d, MONSTER_COUNT
    jb draw_monsters
    PLACE_CHAR playerX, playerY, 'P'

    mov rcx, [hOut]
    xor edx, edx
    call SetConsoleCursorPosition

    mov rcx, [hOut]
    lea rdx, gridBuffer
    mov r8d, GRID_BUF_SIZE
    lea r9, bytesWritten
    mov qword ptr [rsp+20h], 0
    call WriteConsoleA

    mov rdx, [rsp]
    test rdx, rdx
    jne have_line
    lea rdx, statusLine
have_line:
    mov rcx, [hOut]
    mov r8d, LINE_LEN
    lea r9, bytesWritten
    mov qword ptr [rsp+20h], 0
    call WriteConsoleA

    add rsp, 28h
    pop rdi
    pop rsi
    ret
DrawBoard endp

EndGame proc
    ; 화면그리기와 메시지를 출력을 담당 (키입력 대기 포함)
    sub rsp, 28h

    call DrawBoard
    xor edx, edx
    call ReadKey

    add rsp, 28h
    ret
EndGame endp

ReadKey proc
    ; DL=0이면 아무 키, DL=1이면 wasd/q만 허용. AL=방향(0-3) 또는 FFh
    sub rsp, 28h
    mov byte ptr [rsp+8], dl

read_key:
    mov rcx, [hIn]
    lea rdx, inputRec
    mov r8d, 1
    lea r9, numRead
    call ReadConsoleInputA

    mov ax, inputRec.EventType
    cmp ax, KEY_EVENT
    jne read_key
    mov eax, inputRec.KeyEvent.bKeyDown
    test eax, eax
    jz read_key
    movzx eax, inputRec.KeyEvent.uChar
    and al, 0FFh
    or al, 20h

    mov dl, byte ptr [rsp+8]
    test dl, dl
    jz done

    cmp al, 'q'
    je done_q
    lea r9, keyTable
    xor r8d, r8d
filter_key:
    cmp al, byte ptr [r9+r8]
    je done_move
    inc r8d
    cmp r8d, 4
    jb filter_key
    jmp read_key

done_move:
    mov al, r8b
    jmp done
done_q:
    mov al, 0FFh
    jmp done
done:
    add rsp, 28h
    ret
ReadKey endp

ApplyMove proc
    ; RCX=x 포인터, RDX=y 포인터, R8D=방향 인덱스
    sub rsp, 28h

    mov r9, rcx
    mov r10, rdx
    movzx eax, byte ptr [r9]
    movzx ecx, byte ptr [r10]

    lea r11, dxTable
    movsx r11d, byte ptr [r11+r8]
    add eax, r11d
    lea r11, dyTable
    movsx r11d, byte ptr [r11+r8]
    add ecx, r11d

    cmp eax, 0
    jge clamp_x_high
    xor eax, eax
    jmp clamp_y
clamp_x_high:
    cmp eax, MAX_IDX
    jle clamp_y
    mov eax, MAX_IDX

clamp_y:
    cmp ecx, 0
    jge clamp_y_high
    xor ecx, ecx
    jmp store_pos
clamp_y_high:
    cmp ecx, MAX_IDX
    jle store_pos
    mov ecx, MAX_IDX

store_pos:
    mov [r9], al
    mov [r10], cl

    add rsp, 28h
    ret
ApplyMove endp

IsMonsterAt proc
    ; ECX=x, EDX=y, R8D=건너뛸 인덱스(없으면 0FFFFFFFFh). AL=1이면 충돌처리
    sub rsp, 28h

    lea r9, monstersX
    lea r10, monstersY
    xor r11d, r11d
check_loop:
    cmp r11d, r8d
    je next_mon
    mov al, byte ptr [r9+r11]
    cmp al, cl
    jne next_mon
    mov al, byte ptr [r10+r11]
    cmp al, dl
    je hit
next_mon:
    inc r11d
    cmp r11d, MONSTER_COUNT
    jb check_loop
    xor eax, eax
    jmp done
hit:
    mov al, 1
done:
    add rsp, 28h
    ret
IsMonsterAt endp

InitFood proc
    ; GetTickCount로 음식 시작 위치를 정합니다.
    sub rsp, 28h

    mov r8d, 32
seed_loop:
    call GetTickCount
    mov edx, eax
    and edx, MAX_IDX
    mov ecx, eax
    shr ecx, 4
    and ecx, MAX_IDX
    mov [foodX], dl
    mov [foodY], cl

    mov al, [foodX]
    cmp al, [playerX]
    jne chk_m1
    mov al, [foodY]
    cmp al, [playerY]
    je retry
chk_m1:
    movzx ecx, byte ptr [foodX]
    movzx edx, byte ptr [foodY]
    mov r8d, 0FFFFFFFFh
    call IsMonsterAt
    test al, al
    jnz retry
    jmp done

retry:
    dec r8d
    jnz seed_loop
    mov byte ptr [foodX], 8
    mov byte ptr [foodY], 8

done:
    add rsp, 28h
    ret
InitFood endp

start proc
    sub rsp, 28h

    mov ecx, STD_INPUT_HANDLE
    call GetStdHandle
    mov [hIn], rax

    mov ecx, STD_OUTPUT_HANDLE
    call GetStdHandle
    mov [hOut], rax

    mov rcx, [hIn]
    lea rdx, inMode
    call GetConsoleMode

    mov eax, [inMode]
    and eax, NOT (ENABLE_LINE_INPUT or ENABLE_ECHO_INPUT)
    mov rcx, [hIn]
    mov edx, eax
    call SetConsoleMode

    call InitFood
    xor ecx, ecx
    call DrawBoard

game_loop:
    mov edx, 1
    call ReadKey

    cmp al, 0FFh
    je quit_game
    movzx r8d, al
    lea rcx, playerX
    lea rdx, playerY
    call ApplyMove

move_done:
    movzx ecx, byte ptr [playerX]
    movzx edx, byte ptr [playerY]
    mov r8d, 0FFFFFFFFh
    call IsMonsterAt
    test al, al
    jnz lose_game

check_food:
    CHECK_HIT foodX, foodY, move_monster
    jmp win_game

move_monster:
    call GetTickCount
    and eax, 1
    mov r9d, eax
    xor r12d, r12d
move_mon_loop:
    lea rcx, monstersX
    add rcx, r12
    lea rdx, monstersY
    add rdx, r12
    movzx r10d, byte ptr [rcx]
    movzx r11d, byte ptr [rdx]
    lea r15, monDir
    movzx r13d, byte ptr [r15+r12]
    add r13d, 1
    add r13d, r9d
    and r13d, 3
    xor r14d, r14d
pick_dir:
    mov eax, r13d
    add eax, r14d
    and eax, 3
    mov r8d, eax

    lea rax, dxTable
    movsx r15d, byte ptr [rax+r8]
    lea rax, dyTable
    movsx r9d, byte ptr [rax+r8]

    mov eax, r10d
    add eax, r15d
    cmp eax, 0
    jl dir_next
    cmp eax, MAX_IDX
    jg dir_next
    mov ecx, r11d
    add ecx, r9d
    cmp ecx, 0
    jl dir_next
    cmp ecx, MAX_IDX
    jg dir_next

    lea rsi, monstersX
    lea rdi, monstersY
    xor ebx, ebx
occ_loop:
    cmp ebx, r12d
    je occ_next
    movzx r15d, byte ptr [rsi+rbx]
    cmp eax, r15d
    jne occ_next
    movzx r15d, byte ptr [rdi+rbx]
    cmp ecx, r15d
    je dir_next
occ_next:
    inc ebx
    cmp ebx, MONSTER_COUNT
    jb occ_loop
    jmp dir_ok

dir_next:
    inc r14d
    cmp r14d, 4
    jb pick_dir
    jmp skip_move

dir_ok:
    lea rax, monDir
    mov byte ptr [rax+r12], r8b
    lea rcx, monstersX
    add rcx, r12
    lea rdx, monstersY
    add rdx, r12
    call ApplyMove
skip_move:
    inc r12d
    cmp r12d, MONSTER_COUNT
    jb move_mon_loop

    movzx ecx, byte ptr [playerX]
    movzx edx, byte ptr [playerY]
    mov r8d, 0FFFFFFFFh
    call IsMonsterAt
    test al, al
    jnz lose_game

draw_and_loop:
    xor ecx, ecx
    call DrawBoard
    jmp game_loop

win_game:
    lea rcx, winLine
    call EndGame
    jmp quit_game

lose_game:
    lea rcx, loseLine
    call EndGame

quit_game:
    xor ecx, ecx
    call ExitProcess
start endp

end
