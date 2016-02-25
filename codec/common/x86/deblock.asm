;*!
;* \copy
;*     Copyright (c)  2009-2013, Cisco Systems
;*     All rights reserved.
;*
;*     Redistribution and use in source and binary forms, with or without
;*     modification, are permitted provided that the following conditions
;*     are met:
;*
;*        * Redistributions of source code must retain the above copyright
;*          notice, this list of conditions and the following disclaimer.
;*
;*        * Redistributions in binary form must reproduce the above copyright
;*          notice, this list of conditions and the following disclaimer in
;*          the documentation and/or other materials provided with the
;*          distribution.
;*
;*     THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;*     "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;*     LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
;*     FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
;*     COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
;*     INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
;*     BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
;*     LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
;*     CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
;*     LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
;*     ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
;*     POSSIBILITY OF SUCH DAMAGE.
;*
;*
;*  deblock.asm
;*
;*  Abstract
;*      edge loop
;*
;*  History
;*      08/07/2009 Created
;*
;*
;*************************************************************************/
%include "asm_inc.asm"

;*******************************************************************************
; Macros and other preprocessor constants
;*******************************************************************************

SECTION .rodata align=16

ALIGN   16
FOUR_16B_SSE2:   dw   4, 4, 4, 4, 4, 4, 4, 4

ALIGN   16
WELS_DB1_16:
    times 16 db 1
WELS_DB127_16:
    times 16 db 127
WELS_DB96_16:
    times 16 db 96
WELS_SHUFB0000111122223333:
    times 4 db 0
    times 4 db 1
    times 4 db 2
    times 4 db 3


SECTION .text

; Unsigned byte absolute difference.
; a=%1 b=%2 clobber=%3
; Subtract once in each direction with saturation and return the maximum.
%macro SSE2_AbsDiffUB 3
    movdqa   %3, %2
    psubusb  %3, %1
    psubusb  %1, %2
    por      %1, %3
%endmacro

; Unsigned byte compare less than.
; lhs=%1 rhs^0x7f=%2 0x7f=%3
; No unsigned byte lt/gt compare instruction available; xor by 0x7f and use a
; signed compare. Some other options do exist. This one allows modifying the lhs
; without mov and uses a bitwise op which can be executed on most ports on
; common architectures.
%macro SSE2_CmpltUB 3
    pxor     %1, %3
    pcmpgtb  %1, %2
%endmacro

; Unsigned byte compare greater than or equal.
%macro SSE2_CmpgeUB 2
    pminub   %1, %2
    pcmpeqb  %1, %2
%endmacro

; Clip unsigned bytes to ref +/- diff.
; data=%1 ref=%2 maxdiff_from_ref=%3 clobber=%4
%macro SSE2_ClipUB 4
    movdqa   %4, %2
    psubusb  %4, %3
    paddusb  %3, %2
    pmaxub   %1, %4
    pminub   %1, %3
%endmacro

; (a + b + 1 - c) >> 1
; a=%1 b=%2 c=%3 [out:a^b&c]=%4
%macro SSE2_AvgbFloor1 4
    movdqa   %4, %1
    pxor     %4, %2
    pavgb    %1, %2
    pand     %4, %3
    psubb    %1, %4
%endmacro

; (a + b + carry) >> 1
; a=%1 b=%2 carry-1=%3
%macro SSE2_AvgbFloor2 3
    pxor     %1, %3
    pxor     %2, %3
    pavgb    %1, %2
    pxor     %1, %3
%endmacro

; a = (a & m) | (b & ~m)
; a=%1 b=%2 m=%3
%macro SSE2_Blend 3
    pand     %1, %3
    pandn    %3, %2
    por      %1, %3
%endmacro

; Compute
; p0 = clip(p0 + clip((q0 - p0 + ((p1 - q1) >> 2) + 1) >> 1, -iTc, iTc), 0, 255)
; q0 = clip(q0 - clip((q0 - p0 + ((p1 - q1) >> 2) + 1) >> 1, -iTc, iTc), 0, 255)
; 16-wide parallel in packed byte representation in xmm registers.
;
; p1=%1 p0=%2 q0=%3 q1=%4 iTc=%5 FFh=%6 xmmclobber=%7,%8
%macro SSE2_DeblockP0Q0_Lt4 8
    ; (q0 - p0 + ((p1 - q1) >> 2) + 1) >> 1 clipped to [-96, 159] and biased to [0, 255].
    ; A limited range is sufficient because the value is clipped to [-iTc, iTc] later.
    ; Bias so that unsigned saturation can be used.
    ; Get ((p1 - q1) >> 2) + 192 via a pxor and two pavgbs.
    ; q0 - p0 is split into a non-negative and non-positive part. The latter is
    ; subtracted from the biased value.
    movdqa     %7, %2
    psubusb    %7, %3  ; clip(p0 - q0, 0, 255)
    ; ((p1 - q1) >> 2) + 0xc0
    pxor       %4, %6  ; q1 ^ 0xff aka -q1 - 1 & 0xff
    pavgb      %1, %4  ; (((p1 - q1 + 0x100) >> 1)
    pavgb      %1, %6  ;  + 0x100) >> 1
    psubusb    %1, %7  ; -= clip(p0 - q0, 0, 255) saturate.
    movdqa     %8, %3
    psubusb    %8, %2  ; (clip(q0 - p0, 0, 255)
    pavgb      %8, %1  ;  + clip(((p1 - q1 + 0x300) >> 2) - clip(p0 - q0, 0, 255), 0, 255) + 1) >> 1

    ; Unbias and split into a non-negative and a non-positive part.
    ; Clip each part to iTc via minub.
    ; Add/subtract each part to/from p0/q0 and clip.
    movdqa     %6, [WELS_DB96_16]
    psubusb    %6, %8
    psubusb    %8, [WELS_DB96_16]
    pminub     %6, %5
    pminub     %8, %5
    psubusb    %2, %6
    paddusb    %2, %8  ; p0
    paddusb    %3, %6
    psubusb    %3, %8  ; q0
%endmacro


;*******************************************************************************
;    void DeblockLumaLt4V_ssse3(uint8_t * pPix, int32_t iStride, int32_t iAlpha,
;                                 int32_t iBeta, int8_t * pTC)
;*******************************************************************************

WELS_EXTERN DeblockLumaLt4V_ssse3
    %assign push_num 0
    LOAD_5_PARA
    PUSH_XMM 8
    SIGN_EXTENSION r1, r1d
    movd     xmm1, arg3d
    movd     xmm2, arg4d
    pxor     xmm3, xmm3
    pxor     xmm1, [WELS_DB127_16]
    pxor     xmm2, [WELS_DB127_16]
    pshufb   xmm1, xmm3                       ; iAlpha ^ 0x7f
    pshufb   xmm2, xmm3                       ; iBeta  ^ 0x7f
    mov      r2, r1                           ; iStride
    neg      r1                               ; -iStride
    lea      r3, [r0 + r1]                    ; pPix - iStride

    ; Compute masks to enable/disable deblocking.
    MOVDQ    xmm6, [r3 + 0 * r1]              ; p0
    MOVDQ    xmm7, [r3 + 1 * r1]              ; p1
    MOVDQ    xmm0, [r0 + 0 * r2]              ; q0
    movdqa   xmm4, xmm6
    SSE2_AbsDiffUB xmm6, xmm0, xmm3           ; |p0 - q0|
    SSE2_CmpltUB xmm6, xmm1, [WELS_DB127_16]  ; bDeltaP0Q0 = |p0 - q0| < iAlpha
    MOVDQ    xmm1, [r0 + 1 * r2]              ; q1
    SSE2_AbsDiffUB xmm7, xmm4, xmm3           ; |p1 - p0|
    SSE2_AbsDiffUB xmm0, xmm1, xmm3           ; |q1 - q0|
    pmaxub   xmm7, xmm0                       ; max(|p1 - p0|, |q1 - q0|)
    SSE2_CmpltUB xmm7, xmm2, [WELS_DB127_16]  ; bDeltaP1P0 & bDeltaQ1Q0 = max(|p1 - p0|, |q1 - q0|) < iBeta
    pand     xmm6, xmm7                       ; bDeltaP0Q0P1P0Q1Q0 = bDeltaP0Q0 & bDeltaP1P0 & bDeltaQ1Q0
    MOVDQ    xmm7, [r3 + 2 * r1]              ; p2
    movdqa   xmm0, xmm7
    SSE2_AbsDiffUB xmm7, xmm4, xmm3           ; |p2 - p0|
    SSE2_CmpltUB xmm7, xmm2, [WELS_DB127_16]  ; bDeltaP2P0 = |p2 - p0| < iBeta
    MOVDQ    xmm5, [r0 + 2 * r2]              ; q2
    MOVDQ    xmm3, [r0 + 0 * r2]              ; q0
    movdqa   xmm1, xmm5
    SSE2_AbsDiffUB xmm5, xmm3, xmm4           ; |q2 - q0|
    SSE2_CmpltUB xmm5, xmm2, [WELS_DB127_16]  ; bDeltaQ2Q0 = |q2 - q0| < iBeta

    pavgb    xmm3, [r3 + 0 * r1]
    pcmpeqw  xmm2, xmm2  ; FFh
    pxor     xmm3, xmm2
    ; (p2 + ((p0 + q0 + 1) >> 1)) >> 1
    pxor     xmm0, xmm2
    pavgb    xmm0, xmm3
    pxor     xmm0, xmm2
    ; (q2 + ((p0 + q0 + 1) >> 1)) >> 1
    pxor     xmm1, xmm2
    pavgb    xmm1, xmm3
    pxor     xmm1, xmm2

    movd     xmm3, [r4]
    pshufb   xmm3, [WELS_SHUFB0000111122223333] ; iTc
    movdqa   xmm4, xmm3  ; iTc0 = iTc
    pcmpgtb  xmm3, xmm2  ; iTc > -1 ? 0xff : 0x00
    pand     xmm6, xmm3  ; bDeltaP0Q0P1P0Q1Q0 &= iTc > -1
    movdqa   xmm3, xmm4
    psubb    xmm3, xmm7  ; iTc -= bDeltaP2P0 ? -1 : 0
    psubb    xmm3, xmm5  ; iTc -= bDeltaQ2Q0 ? -1 : 0
    pand     xmm3, xmm6  ; iTc &= bDeltaP0Q0P1P0Q1Q0 ? 0xff : 0
    pand     xmm7, xmm6  ; bDeltaP2P0 &= bDeltaP0Q0P1P0Q1Q0
    pand     xmm5, xmm6  ; bDeltaQ2Q0 &= bDeltaP0Q0P1P0Q1Q0
    pand     xmm7, xmm4  ; iTc0 & (bDeltaP2P0 ? 0xff : 0)
    pand     xmm5, xmm4  ; iTc0 & (bDeltaQ2Q0 ? 0xff : 0)

    MOVDQ    xmm4, [r3 + 1 * r1]
    SSE2_ClipUB xmm0, xmm4, xmm7, xmm6  ; clip p1.
    MOVDQ    xmm6, [r0 + 1 * r2]
    MOVDQ    [r3 + 1 * r1], xmm0        ; store p1.
    SSE2_ClipUB xmm1, xmm6, xmm5, xmm7  ; clip q1.
    MOVDQ    [r0 + 1 * r2], xmm1        ; store q1.

    MOVDQ    xmm1, [r3 + 0 * r1]  ; p0
    MOVDQ    xmm0, [r0 + 0 * r2]  ; q0
    SSE2_DeblockP0Q0_Lt4 xmm4, xmm1, xmm0, xmm6, xmm3, xmm2, xmm5, xmm7
    MOVDQ    [r3 + 0 * r1], xmm1  ; store p0.
    MOVDQ    [r0 + 0 * r2], xmm0  ; store q0.

    POP_XMM
    LOAD_5_PARA_POP
    ret


; Deblock 3x16 luma pixels for the eq4 case.
;
; Compose 8-bit averages from pavgbs. Ie. (p1 + p0 + p2 + q0 + 2) >> 2 can be
; written as (((p1 + p0) >> 1) + ((p2 + q0 + (p1 ^ p0 & 1)) >> 1) + 1) >> 1,
; which maps to 3 pavgbs.
;
; pPix=%1 iStride=%2 [in:q0,out:p0]=%3 [in:q1,out:p1]=%4 bDeltaP0Q0P1P0Q1Q0=%5 bDeltaP2P0=%6 clobber=%7,%8,%9,%10 preserve_p0p1=%11 db1=%12
%macro SSE2_DeblockLumaEq4_3x16P 12
    movdqa   %7, %3
    movdqa   %8, %6
    MOVDQ    %10, [%1 + 1 * %2]                      ; p1
    SSE2_Blend %7, %10, %8                           ; t0 = bDeltaP2P0 ? q0 : p1
    movdqa   %8, %6
    MOVDQ    %9, [%1 + 2 * %2]                       ; p2
    SSE2_Blend %9, %4, %8                            ; t1 = bDeltaP2P0 ? p2 : q1
    SSE2_AvgbFloor1 %4,  %9,   %12, %8               ; t1 = (t1 + q1) >> 1
    SSE2_AvgbFloor1 %10, [%1], %12, %8               ; (p0 + p1) >> 1, p0 ^ p1
    pxor     %8, %12
    SSE2_AvgbFloor1 %7, %4, %8, %9                   ; (t0 + t1 + (p0 ^ p1 & 1)) >> 1
    MOVDQ    %9, [%1 + 2 * %2]                       ; p2
    SSE2_AvgbFloor1 %3, %9, %8, %4                   ; (p2 + q0 + (p0 ^ p1 & 1)) >> 1
    pavgb    %7, %10                                 ; p0' = (p0 + p1 + t0 + t1 + 2) >> 2
    movdqa   %8, %10
    pxor     %8, %3                                  ; (p0 + p1) >> 1 ^ (p2 + q0 + (p0 ^ p1 & 1)) >> 1
    pand     %8, %12                                 ; & 1
    pavgb    %10, %3                                 ; p1' = (p0 + p1 + p2 + q0 + 2) >> 2
    pand     %6, %5                                  ; bDeltaP2P0 &= bDeltaP0Q0P1P0Q1Q0
%if %11
    MOVDQ    %3, [%1 + 0 * %2]                       ; p0
    movdqa   %4, %5
    SSE2_Blend %7, %3, %4                            ; p0out = bDeltaP0Q0P1P0Q1Q0 ? p0' : p0
%else
    SSE2_Blend %7, [%1 + 0 * %2], %5                 ; p0out = bDeltaP0Q0P1P0Q1Q0 ? p0' : p0
%endif
    MOVDQ    [%1 + 0 * %2], %7                       ; store p0
    add      %1, %2
    movdqa   %7, %10
    psubb    %10, %8                                 ; (p0 + p1 + p2 + q0) >> 2
    psubb    %8, %12
    MOVDQ    %4, [%1 + (3 - 1) * %2]                 ; p3
    SSE2_AvgbFloor2 %4, %9, %8                       ; (p2 + p3 + ((p0 + p1) >> 1 ^ (p2 + q0 + (p0 ^ p1 & 1)) >> 1 & 1)) >> 1
    pavgb    %10, %4                                 ; p2' = (((p0 + p1 + p2 + q0) >> 1) + p2 + p3 + 2) >> 2
    movdqa   %8, %6
    SSE2_Blend %10, [%1 + (2 - 1) * %2], %8          ; p2out = bDeltaP2P0 ? p2' : p2
    MOVDQ    [%1 + (2 - 1) * %2], %10                ; store p2
%if %11
    MOVDQ    %4, [%1 + (1 - 1) * %2]                 ; p1
    SSE2_Blend %7, %4, %6                            ; p1out = bDeltaP2P0 ? p1' : p1
%else
    SSE2_Blend %7, [%1 + (1 - 1) * %2], %6           ; p1out = bDeltaP2P0 ? p1' : p1
%endif
    MOVDQ    [%1 + (1 - 1) * %2], %7                 ; store p1
%endmacro


;*******************************************************************************
;    void DeblockLumaEq4V_ssse3(uint8_t * pPix, int32_t iStride, int32_t iAlpha,
;                                 int32_t iBeta)
;*******************************************************************************

WELS_EXTERN DeblockLumaEq4V_ssse3
    %assign push_num 0
    LOAD_4_PARA
    PUSH_XMM 10
    SIGN_EXTENSION r1, r1d
    movd     xmm1, arg3d
    movd     xmm2, arg4d
    shr      r2, 2
    add      r2, 1
    movd     xmm3, r2d
    pxor     xmm4, xmm4
    pxor     xmm1, [WELS_DB127_16]
    pxor     xmm2, [WELS_DB127_16]
    pshufb   xmm1, xmm4                       ; iAlpha ^ 0x7f
    pshufb   xmm2, xmm4                       ; iBeta  ^ 0x7f
    pshufb   xmm3, xmm4                       ; (iAlpha >> 2) + 1
    mov      r2, r1                           ; iStride
    neg      r1                               ; -iStride
    lea      r3, [r0 + r1]                    ; pPix - iStride

    ; Compute masks to enable/disable filtering.
    MOVDQ    xmm7, [r3 + 1 * r1]              ; p1
    MOVDQ    xmm6, [r3 + 0 * r1]              ; p0
    MOVDQ    xmm0, [r0 + 0 * r2]              ; q0
    movdqa   xmm4, xmm6
    SSE2_AbsDiffUB xmm6, xmm0, xmm5           ; |p0 - q0|
    SSE2_CmpgeUB xmm3, xmm6                   ; |p0 - q0| < (iAlpha >> 2) + 2
    SSE2_CmpltUB xmm6, xmm1, [WELS_DB127_16]  ; bDeltaP0Q0 = |p0 - q0| < iAlpha
    MOVDQ    xmm1, [r0 + 1 * r2]              ; q1
    SSE2_AbsDiffUB xmm7, xmm4, xmm5           ; |p1 - p0|
    SSE2_AbsDiffUB xmm0, xmm1, xmm5           ; |q1 - q0|
    pmaxub   xmm7, xmm0                       ; max(|p1 - p0|, |q1 - q0|)
    SSE2_CmpltUB xmm7, xmm2, [WELS_DB127_16]  ; bDeltaP1P0 & bDeltaQ1Q0 = max(|p1 - p0|, |q1 - q0|) < iBeta
    pand     xmm6, xmm7                       ; & bDeltaP0Q0

    MOVDQ    xmm7, [r3 + 2 * r1]              ; p2
    SSE2_AbsDiffUB xmm7, xmm4, xmm5           ; |p2 - p0|
    SSE2_CmpltUB xmm7, xmm2, [WELS_DB127_16]  ; bDeltaP2P0 = |p2 - p0| < iBeta
    pand     xmm7, xmm3                       ; &= |p0 - q0| < (iAlpha >> 2) + 2

    MOVDQ    xmm0, [r0 + 0 * r2]              ; q0
    MOVDQ    xmm5, [r0 + 2 * r2]              ; q2
    SSE2_AbsDiffUB xmm5, xmm0, xmm4           ; |q2 - q0|
    SSE2_CmpltUB xmm5, xmm2, [WELS_DB127_16]  ; bDeltaQ2Q0 = |q2 - q0| < iBeta
    pand     xmm5, xmm3                       ; &= |p0 - q0| < (iAlpha >> 2) + 2

%ifdef X86_32
    ; Push xmm5 to free up one register. Align stack so as to ensure that failed
    ; store forwarding penalty cannot occur (up to ~50 cycles for 128-bit on IVB).
    mov      r2, esp
    sub      esp,  16
    and      esp, -16
    movdqa   [esp], xmm5
    SSE2_DeblockLumaEq4_3x16P r3, r1, xmm0, xmm1, xmm6, xmm7, xmm2, xmm3, xmm5, xmm4, 1, [WELS_DB1_16]
    movdqa   xmm5, [esp]
    mov      esp, r2
    neg      r1
    SSE2_DeblockLumaEq4_3x16P r0, r1, xmm0, xmm1, xmm6, xmm5, xmm2, xmm3, xmm7, xmm4, 0, [WELS_DB1_16]
%else
    movdqa   xmm9, [WELS_DB1_16]
    SSE2_DeblockLumaEq4_3x16P r3, r1, xmm0, xmm1, xmm6, xmm7, xmm2, xmm3, xmm8, xmm4, 1, xmm9
    SSE2_DeblockLumaEq4_3x16P r0, r2, xmm0, xmm1, xmm6, xmm5, xmm2, xmm3, xmm7, xmm4, 0, xmm9
%endif

    POP_XMM
    LOAD_4_PARA_POP
    ret


; [out:p1,p0,q0,q1]=%1,%2,%3,%4 pPixCb=%5 pPixCr=%6 iStride=%7 3*iStride-1=%8 xmmclobber=%9,%10,%11
%macro SSE2_LoadCbCr_4x16H 11
    movd       %1,  [%5 + 0 * %7 - 2]  ; [p1,p0,q0,q1] cb line 0
    movd       %2,  [%5 + 2 * %7 - 2]  ; [p1,p0,q0,q1] cb line 2
    punpcklbw  %1,  %2                 ; [p1,p1,p0,p0,q0,q0,q1,q1] cb line 0,2
    movd       %2,  [%5 + 4 * %7 - 2]  ; [p1,p0,q0,q1] cb line 4
    movd       %9,  [%5 + 2 * %8]      ; [p1,p0,q0,q1] cb line 6
    punpcklbw  %2,  %9                 ; [p1,p1,p0,p0,q0,q0,q1,q1] cb line 4,6
    punpcklwd  %1,  %2                 ; [p1,p1,p1,p1,p0,p0,p0,p0,q0,q0,q0,q0,q1,q1,q1,q1] cb line 0,2,4,6
    movd       %2,  [%6 + 0 * %7 - 2]  ; [p1,p0,q0,q1] cr line 0
    movd       %9,  [%6 + 2 * %7 - 2]  ; [p1,p0,q0,q1] cr line 2
    punpcklbw  %2,  %9                 ; [p1,p1,p0,p0,q0,q0,q1,q1] cr line 0,2
    movd       %9,  [%6 + 4 * %7 - 2]  ; [p1,p0,q0,q1] cr line 4
    movd       %10, [%6 + 2 * %8]      ; [p1,p0,q0,q1] cr line 6
    punpcklbw  %9,  %10                ; [p1,p1,p0,p0,q0,q0,q1,q1] cr line 4,6
    punpcklwd  %2,  %9                 ; [p1,p1,p1,p1,p0,p0,p0,p0,q0,q0,q0,q0,q1,q1,q1,q1] cr line 0,2,4,6
    add        %5,  %7                 ; pPixCb += iStride
    add        %6,  %7                 ; pPixCr += iStride
    movd       %9,  [%5 + 0 * %7 - 2]  ; [p1,p0,q0,q1] cb line 1
    movd       %10, [%5 + 2 * %7 - 2]  ; [p1,p0,q0,q1] cb line 3
    punpcklbw  %9,  %10                ; [p1,p1,p0,p0,q0,q0,q1,q1] cb line 1,3
    movd       %10, [%5 + 4 * %7 - 2]  ; [p1,p0,q0,q1] cb line 5
    movd       %3,  [%5 + 2 * %8]      ; [p1,p0,q0,q1] cb line 7
    punpcklbw  %10, %3                 ; [p1,p1,p0,p0,q0,q0,q1,q1] cb line 5,7
    punpcklwd  %9,  %10                ; [p1,p1,p1,p1,p0,p0,p0,p0,q0,q0,q0,q0,q1,q1,q1,q1] cb line 1,3,5,7
    movd       %10, [%6 + 0 * %7 - 2]  ; [p1,p0,q0,q1] cr line 1
    movd       %3,  [%6 + 2 * %7 - 2]  ; [p1,p0,q0,q1] cr line 3
    punpcklbw  %10, %3                 ; [p1,p1,p0,p0,q0,q0,q1,q1] cr line 1,3
    movd       %3,  [%6 + 4 * %7 - 2]  ; [p1,p0,q0,q1] cr line 5
    movd       %4,  [%6 + 2 * %8]      ; [p1,p0,q0,q1] cr line 7
    punpcklbw  %3,  %4                 ; [p1,p1,p0,p0,q0,q0,q1,q1] cr line 5,7
    punpcklwd  %10, %3                 ; [p1,p1,p1,p1,p0,p0,p0,p0,q0,q0,q0,q0,q1,q1,q1,q1] cr line 1,3,5,7
    movdqa     %3,  %1
    punpckldq  %1,  %2                 ; [p1,p1,p1,p1,p1,p1,p1,p1,p0,p0,p0,p0,p0,p0,p0,p0] cb/cr line 0,2,4,6
    punpckhdq  %3,  %2                 ; [q0,q0,q0,q0,q0,q0,q0,q0,q1,q1,q1,q1,q1,q1,q1,q1] cb/cr line 0,2,4,6
    movdqa     %11, %9
    punpckldq  %9,  %10                ; [p1,p1,p1,p1,p1,p1,p1,p1,p0,p0,p0,p0,p0,p0,p0,p0] cb/cr line 1,3,5,7
    punpckhdq  %11, %10                ; [q0,q0,q0,q0,q0,q0,q0,q0,q1,q1,q1,q1,q1,q1,q1,q1] cb/cr line 1,3,5,7
    movdqa     %2,  %1
    punpcklqdq %1,  %9                 ; [p1,p1,p1,p1,p1,p1,p1,p1,p1,p1,p1,p1,p1,p1,p1,p1] cb/cr line 0,2,4,6,1,3,5,7
    punpckhqdq %2,  %9                 ; [p0,p0,p0,p0,p0,p0,p0,p0,p0,p0,p0,p0,p0,p0,p0,p0] cb/cr line 0,2,4,6,1,3,5,7
    movdqa     %4,  %3
    punpcklqdq %3,  %11                ; [q0,q0,q0,q0,q0,q0,q0,q0,q0,q0,q0,q0,q0,q0,q0,q0] cb/cr line 0,2,4,6,1,3,5,7
    punpckhqdq %4,  %11                ; [q1,q1,q1,q1,q1,q1,q1,q1,q1,q1,q1,q1,q1,q1,q1,q1] cb/cr line 0,2,4,6,1,3,5,7
%endmacro

; pPixCb+iStride=%1 pPixCr+iStride=%2 iStride=%3 3*iStride-1=%4 p0=%5 q0=%6 rclobber=%7 dwclobber={%8,%9} xmmclobber=%10
%macro SSE2_StoreCbCr_4x16H 10
    movdqa     %10, %5
    punpcklbw  %10, %6                 ; [p0,q0,p0,q0,p0,q0,p0,q0,p0,q0,p0,q0,p0,q0,p0,q0] cb/cr line 0,2,4,6
    punpckhbw  %5, %6                  ; [p0,q0,p0,q0,p0,q0,p0,q0,p0,q0,p0,q0,p0,q0,p0,q0] cb/cr line 1,3,5,7
    mov        %7, r7                  ; preserve stack pointer
    and        r7, -16                 ; align stack pointer
    sub        r7, 32                  ; allocate stack space
    movdqa     [r7     ], %10          ; store [p0,q0,p0,q0,p0,q0,p0,q0,p0,q0,p0,q0,p0,q0,p0,q0] cb/cr line 0,2,4,6 on the stack
    movdqa     [r7 + 16], %5           ; store [p0,q0,p0,q0,p0,q0,p0,q0,p0,q0,p0,q0,p0,q0,p0,q0] cb/cr line 1,3,5,7 on the stack
    mov        %8, [r7 + 16]           ; [p0,q0,p0,q0] cb line 1,3
    mov        [%1 + 0 * %3 - 1], %9   ; store [p0,q0] cb line 1
    shr        %8, 16                  ; [p0,q0] cb line 3
    mov        [%1 + 2 * %3 - 1], %9   ; store [p0,q0] cb line 3
    mov        %8, [r7 + 20]           ; [p0,q0,p0,q0] cb line 5,7
    mov        [%1 + 4 * %3 - 1], %9   ; store [p0,q0] cb line 5
    shr        %8, 16                  ; [p0,q0] cb line 7
    mov        [%1 + 2 * %4 + 1], %9   ; store [p0,q0] cb line 7
    mov        %8, [r7 + 24]           ; [p0,q0,p0,q0] cr line 1,3
    mov        [%2 + 0 * %3 - 1], %9   ; store [p0,q0] cr line 1
    shr        %8, 16                  ; [p0,q0] cr line 3
    mov        [%2 + 2 * %3 - 1], %9   ; store [p0,q0] cr line 3
    mov        %8, [r7 + 28]           ; [p0,q0,p0,q0] cr line 5,7
    mov        [%2 + 4 * %3 - 1], %9   ; store [p0,q0] cr line 5
    shr        %8, 16                  ; [p0,q0] cr line 7
    mov        [%2 + 2 * %4 + 1], %9   ; store [p0,q0] cr line 7
    sub        %1, %3                  ; pPixCb -= iStride
    sub        %2, %3                  ; pPixCr -= iStride
    mov        %8, [r7     ]           ; [p0,q0,p0,q0] cb line 0,2
    mov        [%1 + 0 * %3 - 1], %9   ; store [p0,q0] cb line 0
    shr        %8, 16                  ; [p0,q0] cb line 2
    mov        [%1 + 2 * %3 - 1], %9   ; store [p0,q0] cb line 2
    mov        %8, [r7 +  4]           ; [p0,q0,p0,q0] cb line 4,6
    mov        [%1 + 4 * %3 - 1], %9   ; store [p0,q0] cb line 4
    shr        %8, 16                  ; [p0,q0] cb line 6
    mov        [%1 + 2 * %4 + 1], %9   ; store [p0,q0] cb line 6
    mov        %8, [r7 +  8]           ; [p0,q0,p0,q0] cr line 0,2
    mov        [%2 + 0 * %3 - 1], %9   ; store [p0,q0] cr line 0
    shr        %8, 16                  ; [p0,q0] cr line 2
    mov        [%2 + 2 * %3 - 1], %9   ; store [p0,q0] cr line 2
    mov        %8, [r7 + 12]           ; [p0,q0,p0,q0] cr line 4,6
    mov        [%2 + 4 * %3 - 1], %9   ; store [p0,q0] cr line 4
    shr        %8, 16                  ; [p0,q0] cr line 6
    mov        [%2 + 2 * %4 + 1], %9   ; store [p0,q0] cr line 6
    mov        r7, %7                  ; restore stack pointer
%endmacro

; p1=%1 p0=%2 q0=%3 q1=%4 iAlpha=%5 iBeta=%6 pTC=%7 xmmclobber=%8,%9,%10 interleaveTC=%11
%macro SSSE3_DeblockChromaLt4 11
    movdqa     %8, %3
    SSE2_AbsDiffUB %8, %2, %9           ; |p0 - q0|
    SSE2_CmpgeUB %8, %5                 ; !bDeltaP0Q0 = |p0 - q0| >= iAlpha
    movdqa     %9, %4
    SSE2_AbsDiffUB %9, %3, %5           ; |q1 - q0|
    movdqa     %10, %1
    SSE2_AbsDiffUB %10, %2, %5          ; |p1 - p0|
    pmaxub     %9, %10                  ; max(|q1 - q0|, |p1 - p0|)
    pxor       %10, %10
    movd       %5, %6
    pshufb     %5, %10                  ; iBeta
    SSE2_CmpgeUB %9, %5                 ; !bDeltaQ1Q0 | !bDeltaP1P0 = max(|q1 - q0|, |p1 - p0|) >= iBeta
    por        %8, %9                   ; | !bDeltaP0Q0
    movd       %5, [%7]
%if %11
    punpckldq  %5, %5
    punpcklbw  %5, %5                   ; iTc
%else
    pshufd     %5, %5, 0                ; iTc
%endif
    pcmpeqw    %10, %10                 ; FFh
    movdqa     %9, %5
    pcmpgtb    %9, %10                  ; iTc > -1 ? FFh : 00h
    pandn      %8, %5                   ; iTc & bDeltaP0Q0 & bDeltaP1P0 & bDeltaQ1Q0
    pand       %8, %9                   ; &= (iTc > -1 ? FFh : 00h)
    SSE2_DeblockP0Q0_Lt4 %1, %2, %3, %4, %8, %10, %5, %9
%endmacro


;******************************************************************************
; void DeblockChromaLt4V_ssse3(uint8_t * pPixCb, uint8_t * pPixCr, int32_t iStride,
;                           int32_t iAlpha, int32_t iBeta, int8_t * pTC);
;*******************************************************************************

WELS_EXTERN DeblockChromaLt4V_ssse3
    %assign push_num 0
    LOAD_4_PARA
    PUSH_XMM 8
    SIGN_EXTENSION r2, r2d
    movd     xmm7, arg4d
    pxor     xmm0, xmm0
    pshufb   xmm7, xmm0                       ; iAlpha
    mov      r3, r2
    neg      r3                               ; -iStride

    movq     xmm0, [r0 + 0 * r2]              ; q0 cb
    movhps   xmm0, [r1 + 0 * r2]              ; q0 cr
    movq     xmm2, [r0 + 1 * r3]              ; p0 cb
    movhps   xmm2, [r1 + 1 * r3]              ; p0 cr
    movq     xmm1, [r0 + 1 * r2]              ; q1 cb
    movhps   xmm1, [r1 + 1 * r2]              ; q1 cr
    movq     xmm3, [r0 + 2 * r3]              ; p1 cb
    movhps   xmm3, [r1 + 2 * r3]              ; p1 cr

%ifidni arg6, r5
    SSSE3_DeblockChromaLt4 xmm3, xmm2, xmm0, xmm1, xmm7, arg5d, arg6, xmm4, xmm5, xmm6, 1
%else
    mov      r2, arg6
    SSSE3_DeblockChromaLt4 xmm3, xmm2, xmm0, xmm1, xmm7, arg5d, r2,   xmm4, xmm5, xmm6, 1
%endif

    movlps   [r0 + 1 * r3], xmm2              ; store p0 cb
    movhps   [r1 + 1 * r3], xmm2              ; store p0 cr
    movlps   [r0         ], xmm0              ; store q0 cb
    movhps   [r1         ], xmm0              ; store q0 cr

    POP_XMM
    LOAD_4_PARA_POP
    ret


;********************************************************************************
;  void DeblockChromaEq4V_ssse3(uint8_t * pPixCb, uint8_t * pPixCr, int32_t iStride,
;                             int32_t iAlpha, int32_t iBeta)
;********************************************************************************

WELS_EXTERN DeblockChromaEq4V_ssse3
    %assign push_num 0
    LOAD_4_PARA
    PUSH_XMM 8
    SIGN_EXTENSION r2, r2d
    movd     xmm7, arg4d
    pxor     xmm0, xmm0
    pshufb   xmm7, xmm0                       ; iAlpha
    mov      r3, r2
    neg      r3                               ; -iStride

    movq     xmm0, [r0 + 0 * r2]              ; q0 cb
    movhps   xmm0, [r1 + 0 * r2]              ; q0 cr
    movq     xmm2, [r0 + 1 * r3]              ; p0 cb
    movhps   xmm2, [r1 + 1 * r3]              ; p0 cr

    movdqa   xmm4, xmm0
    SSE2_AbsDiffUB xmm4, xmm2, xmm5           ; |p0 - q0|
    SSE2_CmpgeUB xmm4, xmm7                   ; !bDeltaP0Q0 = |p0 - q0| >= iAlpha

    movq     xmm1, [r0 + 1 * r2]              ; q1 cb
    movhps   xmm1, [r1 + 1 * r2]              ; q1 cr
    movq     xmm3, [r0 + 2 * r3]              ; p1 cb
    movhps   xmm3, [r1 + 2 * r3]              ; p1 cr

    movdqa   xmm5, xmm1
    SSE2_AbsDiffUB xmm5, xmm0, xmm7           ; |q1 - q0|
    movdqa   xmm6, xmm3
    SSE2_AbsDiffUB xmm6, xmm2, xmm7           ; |p1 - p0|
    pmaxub   xmm5, xmm6                       ; max(|q1 - q0|, |p1 - p0|)

    pxor     xmm6, xmm6
    movd     xmm7, arg5d
    pshufb   xmm7, xmm6                       ; iBeta

    SSE2_CmpgeUB xmm5, xmm7                   ; !bDeltaQ1Q0 | !bDeltaP1P0 = max(|q1 - q0|, |p1 - p0|) >= iBeta
    por      xmm4, xmm5                       ; !bDeltaP0Q0P1P0Q1Q0 = !bDeltaP0Q0 | !bDeltaQ1Q0 | !bDeltaP1P0

    WELS_DB1 xmm7
    movdqa   xmm5, xmm2
    SSE2_AvgbFloor1 xmm2, xmm1, xmm7, xmm6    ; (p0 + q1) >> 1
    pavgb    xmm2, xmm3                       ; p0' = (p1 + ((p0 + q1) >> 1) + 1) >> 1
    movdqa   xmm6, xmm4
    SSE2_Blend xmm5, xmm2, xmm4               ; p0out = bDeltaP0Q0P1P0Q1Q0 ? p0' : p0

    SSE2_AvgbFloor1 xmm3, xmm0, xmm7, xmm4    ; (q0 + p1) >> 1
    pavgb    xmm3, xmm1                       ; q0' = (q1 + ((q0 + p1) >> 1) + 1) >> 1
    SSE2_Blend xmm0, xmm3, xmm6               ; q0out = bDeltaP0Q0P1P0Q1Q0 ? q0' : q0

    movlps   [r0 + 1 * r3], xmm5              ; store p0 cb
    movhps   [r1 + 1 * r3], xmm5              ; store p0 cr
    movlps   [r0 + 0 * r2], xmm0              ; store q0 cb
    movhps   [r1 + 0 * r2], xmm0              ; store q0 cr

    POP_XMM
    LOAD_4_PARA_POP
    ret


;*******************************************************************************
;    void DeblockChromaLt4H_ssse3(uint8_t * pPixCb, uint8_t * pPixCr, int32_t iStride,
;                                int32_t iAlpha, int32_t iBeta, int8_t * pTC);
;*******************************************************************************

WELS_EXTERN DeblockChromaLt4H_ssse3
    %assign push_num 0
    LOAD_6_PARA
    PUSH_XMM 8
    SIGN_EXTENSION r2, r2d
    movd       xmm7, arg4d
    pxor       xmm0, xmm0
    pshufb     xmm7, xmm0                       ; iAlpha
    lea        r3, [3 * r2 - 1]                 ; 3 * iStride - 1

    SSE2_LoadCbCr_4x16H xmm0, xmm1, xmm4, xmm5, r0, r1, r2, r3, xmm2, xmm3, xmm6
    SSSE3_DeblockChromaLt4 xmm0, xmm1, xmm4, xmm5, xmm7, arg5d, r5, xmm2, xmm3, xmm6, 0
    SSE2_StoreCbCr_4x16H r0, r1, r2, r3, xmm1, xmm4, r5, r4d, r4w, xmm0

    POP_XMM
    LOAD_6_PARA_POP
    ret


%ifdef  WIN64


WELS_EXTERN DeblockChromaEq4H_ssse3
    mov         rax,rsp
    mov         [rax+20h],rbx
    push        rdi
    PUSH_XMM 16
    sub         rsp,140h
    mov         rdi,rdx
    lea         eax,[r8*4]
    movsxd      r10,eax
    mov         eax,[rcx-2]
    mov         [rsp+10h],eax
    lea         rbx,[r10+rdx-2]
    lea         r11,[r10+rcx-2]
    movdqa      xmm5,[rsp+10h]
    movsxd      r10,r8d
    mov         eax,[r10+rcx-2]
    lea         rdx,[r10+r10*2]
    mov         [rsp+20h],eax
    mov         eax,[rcx+r10*2-2]
    mov         [rsp+30h],eax
    mov         eax,[rdx+rcx-2]
    movdqa      xmm2,[rsp+20h]
    mov         [rsp+40h],eax
    mov         eax, [rdi-2]
    movdqa      xmm4,[rsp+30h]
    mov         [rsp+50h],eax
    mov         eax,[r10+rdi-2]
    movdqa      xmm3,[rsp+40h]
    mov         [rsp+60h],eax
    mov         eax,[rdi+r10*2-2]
    punpckldq   xmm5,[rsp+50h]
    mov         [rsp+70h],eax
    mov         eax, [rdx+rdi-2]
    punpckldq   xmm2, [rsp+60h]
    mov          [rsp+80h],eax
    mov         eax,[r11]
    punpckldq   xmm4, [rsp+70h]
    mov         [rsp+50h],eax
    mov         eax,[rbx]
    punpckldq   xmm3,[rsp+80h]
    mov         [rsp+60h],eax
    mov         eax,[r10+r11]
    movdqa      xmm0, [rsp+50h]
    punpckldq   xmm0, [rsp+60h]
    punpcklqdq  xmm5,xmm0
    movdqa      [rsp+50h],xmm0
    mov         [rsp+50h],eax
    mov         eax,[r10+rbx]
    movdqa      xmm0,[rsp+50h]
    movdqa      xmm1,xmm5
    mov         [rsp+60h],eax
    mov         eax,[r11+r10*2]
    punpckldq   xmm0, [rsp+60h]
    punpcklqdq  xmm2,xmm0
    punpcklbw   xmm1,xmm2
    punpckhbw   xmm5,xmm2
    movdqa      [rsp+50h],xmm0
    mov         [rsp+50h],eax
    mov         eax,[rbx+r10*2]
    movdqa      xmm0,[rsp+50h]
    mov         [rsp+60h],eax
    mov         eax, [rdx+r11]
    movdqa      xmm15,xmm1
    punpckldq   xmm0,[rsp+60h]
    punpcklqdq  xmm4,xmm0
    movdqa      [rsp+50h],xmm0
    mov         [rsp+50h],eax
    mov         eax, [rdx+rbx]
    movdqa      xmm0,[rsp+50h]
    mov         [rsp+60h],eax
    punpckldq   xmm0, [rsp+60h]
    punpcklqdq  xmm3,xmm0
    movdqa      xmm0,xmm4
    punpcklbw   xmm0,xmm3
    punpckhbw   xmm4,xmm3
    punpcklwd   xmm15,xmm0
    punpckhwd   xmm1,xmm0
    movdqa      xmm0,xmm5
    movdqa      xmm12,xmm15
    punpcklwd   xmm0,xmm4
    punpckhwd   xmm5,xmm4
    punpckldq   xmm12,xmm0
    punpckhdq   xmm15,xmm0
    movdqa      xmm0,xmm1
    movdqa      xmm11,xmm12
    punpckldq   xmm0,xmm5
    punpckhdq   xmm1,xmm5
    punpcklqdq  xmm11,xmm0
    punpckhqdq  xmm12,xmm0
    movsx       eax,r9w
    movdqa      xmm14,xmm15
    punpcklqdq  xmm14,xmm1
    punpckhqdq  xmm15,xmm1
    pxor        xmm1,xmm1
    movd        xmm0,eax
    movdqa      xmm4,xmm12
    movdqa      xmm8,xmm11
    movsx       eax,word [rsp+170h + 160] ; iBeta
    punpcklwd   xmm0,xmm0
    punpcklbw   xmm4,xmm1
    punpckhbw   xmm12,xmm1
    movdqa      xmm9,xmm14
    movdqa      xmm7,xmm15
    movdqa      xmm10,xmm15
    pshufd      xmm13,xmm0,0
    punpcklbw   xmm9,xmm1
    punpckhbw   xmm14,xmm1
    movdqa      xmm6,xmm13
    movd        xmm0,eax
    movdqa      [rsp],xmm11
    mov         eax,2
    cwde
    punpckhbw   xmm11,xmm1
    punpckhbw   xmm10,xmm1
    punpcklbw   xmm7,xmm1
    punpcklwd   xmm0,xmm0
    punpcklbw   xmm8,xmm1
    pshufd      xmm3,xmm0,0
    movdqa      xmm1,xmm8
    movdqa      xmm0,xmm4
    psubw       xmm0,xmm9
    psubw       xmm1,xmm4
    movdqa      xmm2,xmm3
    pabsw       xmm0,xmm0
    pcmpgtw     xmm6,xmm0
    pabsw       xmm0,xmm1
    movdqa      xmm1,xmm3
    pcmpgtw     xmm2,xmm0
    pand        xmm6,xmm2
    movdqa      xmm0,xmm7
    movdqa      xmm2,xmm3
    psubw       xmm0,xmm9
    pabsw       xmm0,xmm0
    pcmpgtw     xmm1,xmm0
    pand        xmm6,xmm1
    movdqa      xmm0,xmm12
    movdqa      xmm1,xmm11
    psubw       xmm0,xmm14
    psubw       xmm1,xmm12
    movdqa      xmm5,xmm6
    pabsw       xmm0,xmm0
    pcmpgtw     xmm13,xmm0
    pabsw       xmm0,xmm1
    movdqa      xmm1,xmm8
    pcmpgtw     xmm2,xmm0
    paddw       xmm1,xmm8
    movdqa      xmm0,xmm10
    pand        xmm13,xmm2
    psubw       xmm0,xmm14
    paddw       xmm1,xmm4
    movdqa      xmm2,xmm11
    pabsw       xmm0,xmm0
    paddw       xmm2,xmm11
    paddw       xmm1,xmm7
    pcmpgtw     xmm3,xmm0
    paddw       xmm2,xmm12
    movd        xmm0,eax
    pand        xmm13,xmm3
    paddw       xmm2,xmm10
    punpcklwd   xmm0,xmm0
    pshufd      xmm3,xmm0,0
    movdqa      xmm0,xmm6
    paddw       xmm1,xmm3
    pandn       xmm0,xmm4
    paddw       xmm2,xmm3
    psraw       xmm1,2
    pand        xmm5,xmm1
    por         xmm5,xmm0
    paddw       xmm7,xmm7
    paddw       xmm10,xmm10
    psraw       xmm2,2
    movdqa      xmm1,xmm13
    movdqa      xmm0,xmm13
    pandn       xmm0,xmm12
    pand        xmm1,xmm2
    paddw       xmm7,xmm9
    por         xmm1,xmm0
    paddw       xmm10,xmm14
    paddw       xmm7,xmm8
    movdqa      xmm0,xmm13
    packuswb    xmm5,xmm1
    paddw       xmm7,xmm3
    paddw       xmm10,xmm11
    movdqa      xmm1,xmm6
    paddw       xmm10,xmm3
    pandn       xmm6,xmm9
    psraw       xmm7,2
    pand        xmm1,xmm7
    psraw       xmm10,2
    pandn       xmm13,xmm14
    pand        xmm0,xmm10
    por         xmm1,xmm6
    movdqa      xmm6,[rsp]
    movdqa      xmm4,xmm6
    por         xmm0,xmm13
    punpcklbw   xmm4,xmm5
    punpckhbw   xmm6,xmm5
    movdqa      xmm3,xmm4
    packuswb    xmm1,xmm0
    movdqa      xmm0,xmm1
    punpckhbw   xmm1,xmm15
    punpcklbw   xmm0,xmm15
    punpcklwd   xmm3,xmm0
    punpckhwd   xmm4,xmm0
    movdqa      xmm0,xmm6
    movdqa      xmm2,xmm3
    punpcklwd   xmm0,xmm1
    punpckhwd   xmm6,xmm1
    movdqa      xmm1,xmm4
    punpckldq   xmm2,xmm0
    punpckhdq   xmm3,xmm0
    punpckldq   xmm1,xmm6
    movdqa      xmm0,xmm2
    punpcklqdq  xmm0,xmm1
    punpckhdq   xmm4,xmm6
    punpckhqdq  xmm2,xmm1
    movdqa      [rsp+10h],xmm0
    movdqa      [rsp+60h],xmm2
    movdqa      xmm0,xmm3
    mov         eax,[rsp+10h]
    mov         [rcx-2],eax
    mov         eax,[rsp+60h]
    punpcklqdq  xmm0,xmm4
    punpckhqdq  xmm3,xmm4
    mov         [r10+rcx-2],eax
    movdqa      [rsp+20h],xmm0
    mov         eax, [rsp+20h]
    movdqa      [rsp+70h],xmm3
    mov         [rcx+r10*2-2],eax
    mov         eax,[rsp+70h]
    mov         [rdx+rcx-2],eax
    mov         eax,[rsp+18h]
    mov         [r11],eax
    mov         eax,[rsp+68h]
    mov         [r10+r11],eax
    mov         eax,[rsp+28h]
    mov         [r11+r10*2],eax
    mov         eax,[rsp+78h]
    mov         [rdx+r11],eax
    mov         eax,[rsp+14h]
    mov         [rdi-2],eax
    mov         eax,[rsp+64h]
    mov         [r10+rdi-2],eax
    mov         eax,[rsp+24h]
    mov         [rdi+r10*2-2],eax
    mov         eax, [rsp+74h]
    mov         [rdx+rdi-2],eax
    mov         eax, [rsp+1Ch]
    mov         [rbx],eax
    mov         eax, [rsp+6Ch]
    mov         [r10+rbx],eax
    mov         eax,[rsp+2Ch]
    mov         [rbx+r10*2],eax
    mov         eax,[rsp+7Ch]
    mov         [rdx+rbx],eax
    lea         rsp,[rsp+140h]
    POP_XMM
    mov         rbx, [rsp+28h]
    pop         rdi
    ret



%elifdef  UNIX64


WELS_EXTERN DeblockChromaEq4H_ssse3
    mov         rax,rsp
    push        rbx
    push        rbp
    push        r12

    mov         rbp,   r8
    mov         r8,    rdx
    mov         r9,    rcx
    mov         rcx,   rdi
    mov         rdx,   rsi
    mov         rdi,   rdx

    sub         rsp,140h
    lea         eax,[r8*4]
    movsxd      r10,eax
    mov         eax,[rcx-2]
    mov         [rsp+10h],eax
    lea         rbx,[r10+rdx-2]
    lea         r11,[r10+rcx-2]

    movdqa      xmm5,[rsp+10h]
    movsxd      r10,r8d
    mov         eax,[r10+rcx-2]
    lea         rdx,[r10+r10*2]
    mov         [rsp+20h],eax
    mov         eax,[rcx+r10*2-2]
    mov         [rsp+30h],eax
    mov         eax,[rdx+rcx-2]
    movdqa      xmm2,[rsp+20h]
    mov         [rsp+40h],eax
    mov         eax, [rdi-2]
    movdqa      xmm4,[rsp+30h]
    mov         [rsp+50h],eax
    mov         eax,[r10+rdi-2]
    movdqa      xmm3,[rsp+40h]
    mov         [rsp+60h],eax
    mov         eax,[rdi+r10*2-2]
    punpckldq   xmm5,[rsp+50h]
    mov         [rsp+70h],eax
    mov         eax, [rdx+rdi-2]
    punpckldq   xmm2, [rsp+60h]
    mov          [rsp+80h],eax
    mov         eax,[r11]
    punpckldq   xmm4, [rsp+70h]
    mov         [rsp+50h],eax
    mov         eax,[rbx]
    punpckldq   xmm3,[rsp+80h]
    mov         [rsp+60h],eax
    mov         eax,[r10+r11]
    movdqa      xmm0, [rsp+50h]
    punpckldq   xmm0, [rsp+60h]
    punpcklqdq  xmm5,xmm0
    movdqa      [rsp+50h],xmm0
    mov         [rsp+50h],eax
    mov         eax,[r10+rbx]
    movdqa      xmm0,[rsp+50h]
    movdqa      xmm1,xmm5
    mov         [rsp+60h],eax
    mov         eax,[r11+r10*2]
    punpckldq   xmm0, [rsp+60h]
    punpcklqdq  xmm2,xmm0
    punpcklbw   xmm1,xmm2
    punpckhbw   xmm5,xmm2
    movdqa      [rsp+50h],xmm0
    mov         [rsp+50h],eax
    mov         eax,[rbx+r10*2]
    movdqa      xmm0,[rsp+50h]
    mov         [rsp+60h],eax
    mov         eax, [rdx+r11]
    movdqa      xmm15,xmm1
    punpckldq   xmm0,[rsp+60h]
    punpcklqdq  xmm4,xmm0
    movdqa      [rsp+50h],xmm0
    mov         [rsp+50h],eax
    mov         eax, [rdx+rbx]
    movdqa      xmm0,[rsp+50h]
    mov         [rsp+60h],eax
    punpckldq   xmm0, [rsp+60h]
    punpcklqdq  xmm3,xmm0
    movdqa      xmm0,xmm4
    punpcklbw   xmm0,xmm3
    punpckhbw   xmm4,xmm3
    punpcklwd   xmm15,xmm0
    punpckhwd   xmm1,xmm0
    movdqa      xmm0,xmm5
    movdqa      xmm12,xmm15
    punpcklwd   xmm0,xmm4
    punpckhwd   xmm5,xmm4
    punpckldq   xmm12,xmm0
    punpckhdq   xmm15,xmm0
    movdqa      xmm0,xmm1
    movdqa      xmm11,xmm12
    punpckldq   xmm0,xmm5
    punpckhdq   xmm1,xmm5
    punpcklqdq  xmm11,xmm0
    punpckhqdq  xmm12,xmm0
    movsx       eax,r9w
    movdqa      xmm14,xmm15
    punpcklqdq  xmm14,xmm1
    punpckhqdq  xmm15,xmm1
    pxor        xmm1,xmm1
    movd        xmm0,eax
    movdqa      xmm4,xmm12
    movdqa      xmm8,xmm11
    mov         eax, ebp ; iBeta
    punpcklwd   xmm0,xmm0
    punpcklbw   xmm4,xmm1
    punpckhbw   xmm12,xmm1
    movdqa      xmm9,xmm14
    movdqa      xmm7,xmm15
    movdqa      xmm10,xmm15
    pshufd      xmm13,xmm0,0
    punpcklbw   xmm9,xmm1
    punpckhbw   xmm14,xmm1
    movdqa      xmm6,xmm13
    movd        xmm0,eax
    movdqa      [rsp],xmm11
    mov         eax,2
    cwde
    punpckhbw   xmm11,xmm1
    punpckhbw   xmm10,xmm1
    punpcklbw   xmm7,xmm1
    punpcklwd   xmm0,xmm0
    punpcklbw   xmm8,xmm1
    pshufd      xmm3,xmm0,0
    movdqa      xmm1,xmm8
    movdqa      xmm0,xmm4
    psubw       xmm0,xmm9
    psubw       xmm1,xmm4
    movdqa      xmm2,xmm3
    pabsw       xmm0,xmm0
    pcmpgtw     xmm6,xmm0
    pabsw       xmm0,xmm1
    movdqa      xmm1,xmm3
    pcmpgtw     xmm2,xmm0
    pand        xmm6,xmm2
    movdqa      xmm0,xmm7
    movdqa      xmm2,xmm3
    psubw       xmm0,xmm9
    pabsw       xmm0,xmm0
    pcmpgtw     xmm1,xmm0
    pand        xmm6,xmm1
    movdqa      xmm0,xmm12
    movdqa      xmm1,xmm11
    psubw       xmm0,xmm14
    psubw       xmm1,xmm12
    movdqa      xmm5,xmm6
    pabsw       xmm0,xmm0
    pcmpgtw     xmm13,xmm0
    pabsw       xmm0,xmm1
    movdqa      xmm1,xmm8
    pcmpgtw     xmm2,xmm0
    paddw       xmm1,xmm8
    movdqa      xmm0,xmm10
    pand        xmm13,xmm2
    psubw       xmm0,xmm14
    paddw       xmm1,xmm4
    movdqa      xmm2,xmm11
    pabsw       xmm0,xmm0
    paddw       xmm2,xmm11
    paddw       xmm1,xmm7
    pcmpgtw     xmm3,xmm0
    paddw       xmm2,xmm12
    movd        xmm0,eax
    pand        xmm13,xmm3
    paddw       xmm2,xmm10
    punpcklwd   xmm0,xmm0
    pshufd      xmm3,xmm0,0
    movdqa      xmm0,xmm6
    paddw       xmm1,xmm3
    pandn       xmm0,xmm4
    paddw       xmm2,xmm3
    psraw       xmm1,2
    pand        xmm5,xmm1
    por         xmm5,xmm0
    paddw       xmm7,xmm7
    paddw       xmm10,xmm10
    psraw       xmm2,2
    movdqa      xmm1,xmm13
    movdqa      xmm0,xmm13
    pandn       xmm0,xmm12
    pand        xmm1,xmm2
    paddw       xmm7,xmm9
    por         xmm1,xmm0
    paddw       xmm10,xmm14
    paddw       xmm7,xmm8
    movdqa      xmm0,xmm13
    packuswb    xmm5,xmm1
    paddw       xmm7,xmm3
    paddw       xmm10,xmm11
    movdqa      xmm1,xmm6
    paddw       xmm10,xmm3
    pandn       xmm6,xmm9
    psraw       xmm7,2
    pand        xmm1,xmm7
    psraw       xmm10,2
    pandn       xmm13,xmm14
    pand        xmm0,xmm10
    por         xmm1,xmm6
    movdqa      xmm6,[rsp]
    movdqa      xmm4,xmm6
    por         xmm0,xmm13
    punpcklbw   xmm4,xmm5
    punpckhbw   xmm6,xmm5
    movdqa      xmm3,xmm4
    packuswb    xmm1,xmm0
    movdqa      xmm0,xmm1
    punpckhbw   xmm1,xmm15
    punpcklbw   xmm0,xmm15
    punpcklwd   xmm3,xmm0
    punpckhwd   xmm4,xmm0
    movdqa      xmm0,xmm6
    movdqa      xmm2,xmm3
    punpcklwd   xmm0,xmm1
    punpckhwd   xmm6,xmm1
    movdqa      xmm1,xmm4
    punpckldq   xmm2,xmm0
    punpckhdq   xmm3,xmm0
    punpckldq   xmm1,xmm6
    movdqa      xmm0,xmm2
    punpcklqdq  xmm0,xmm1
    punpckhdq   xmm4,xmm6
    punpckhqdq  xmm2,xmm1
    movdqa      [rsp+10h],xmm0
    movdqa      [rsp+60h],xmm2
    movdqa      xmm0,xmm3
    mov         eax,[rsp+10h]
    mov         [rcx-2],eax
    mov         eax,[rsp+60h]
    punpcklqdq  xmm0,xmm4
    punpckhqdq  xmm3,xmm4
    mov         [r10+rcx-2],eax
    movdqa      [rsp+20h],xmm0
    mov         eax, [rsp+20h]
    movdqa      [rsp+70h],xmm3
    mov         [rcx+r10*2-2],eax
    mov         eax,[rsp+70h]
    mov         [rdx+rcx-2],eax
    mov         eax,[rsp+18h]
    mov         [r11],eax
    mov         eax,[rsp+68h]
    mov         [r10+r11],eax
    mov         eax,[rsp+28h]
    mov         [r11+r10*2],eax
    mov         eax,[rsp+78h]
    mov         [rdx+r11],eax
    mov         eax,[rsp+14h]
    mov         [rdi-2],eax
    mov         eax,[rsp+64h]
    mov         [r10+rdi-2],eax
    mov         eax,[rsp+24h]
    mov         [rdi+r10*2-2],eax
    mov         eax, [rsp+74h]
    mov         [rdx+rdi-2],eax
    mov         eax, [rsp+1Ch]
    mov         [rbx],eax
    mov         eax, [rsp+6Ch]
    mov         [r10+rbx],eax
    mov         eax,[rsp+2Ch]
    mov         [rbx+r10*2],eax
    mov         eax,[rsp+7Ch]
    mov         [rdx+rbx],eax
    lea         r11,[rsp+140h]
    mov         rbx, [r11+28h]
    mov         rsp,r11
    pop         r12
    pop         rbp
    pop         rbx
    ret



%elifdef  X86_32

;***************************************************************************
;  void DeblockChromaEq4H_ssse3(uint8_t * pPixCb, uint8_t * pPixCr, int32_t iStride,
;          int32_t iAlpha, int32_t iBeta)
;***************************************************************************

WELS_EXTERN DeblockChromaEq4H_ssse3
    push        ebp
    mov         ebp,esp
    and         esp,0FFFFFFF0h
    sub         esp,0C8h
    mov         ecx,dword [ebp+8]
    mov         edx,dword [ebp+0Ch]
    mov         eax,dword [ebp+10h]
    sub         ecx,2
    sub         edx,2
    push        esi
    lea         esi,[eax+eax*2]
    mov         dword [esp+18h],ecx
    mov         dword [esp+4],edx
    lea         ecx,[ecx+eax*4]
    lea         edx,[edx+eax*4]
    lea         eax,[esp+7Ch]
    push        edi
    mov         dword [esp+14h],esi
    mov         dword [esp+18h],ecx
    mov         dword [esp+0Ch],edx
    mov         dword [esp+10h],eax
    mov         esi,dword [esp+1Ch]
    mov         ecx,dword [ebp+10h]
    mov         edx,dword [esp+14h]
    movd        xmm0,dword [esi]
    movd        xmm1,dword [esi+ecx]
    movd        xmm2,dword [esi+ecx*2]
    movd        xmm3,dword [esi+edx]
    mov         esi,dword  [esp+8]
    movd        xmm4,dword [esi]
    movd        xmm5,dword [esi+ecx]
    movd        xmm6,dword [esi+ecx*2]
    movd        xmm7,dword [esi+edx]
    punpckldq   xmm0,xmm4
    punpckldq   xmm1,xmm5
    punpckldq   xmm2,xmm6
    punpckldq   xmm3,xmm7
    mov         esi,dword [esp+18h]
    mov         edi,dword [esp+0Ch]
    movd        xmm4,dword [esi]
    movd        xmm5,dword [edi]
    punpckldq   xmm4,xmm5
    punpcklqdq  xmm0,xmm4
    movd        xmm4,dword [esi+ecx]
    movd        xmm5,dword [edi+ecx]
    punpckldq   xmm4,xmm5
    punpcklqdq  xmm1,xmm4
    movd        xmm4,dword [esi+ecx*2]
    movd        xmm5,dword [edi+ecx*2]
    punpckldq   xmm4,xmm5
    punpcklqdq  xmm2,xmm4
    movd        xmm4,dword [esi+edx]
    movd        xmm5,dword [edi+edx]
    punpckldq   xmm4,xmm5
    punpcklqdq  xmm3,xmm4
    movdqa      xmm6,xmm0
    punpcklbw   xmm0,xmm1
    punpckhbw   xmm6,xmm1
    movdqa      xmm7,xmm2
    punpcklbw   xmm2,xmm3
    punpckhbw   xmm7,xmm3
    movdqa      xmm4,xmm0
    movdqa      xmm5,xmm6
    punpcklwd   xmm0,xmm2
    punpckhwd   xmm4,xmm2
    punpcklwd   xmm6,xmm7
    punpckhwd   xmm5,xmm7
    movdqa      xmm1,xmm0
    movdqa      xmm2,xmm4
    punpckldq   xmm0,xmm6
    punpckhdq   xmm1,xmm6
    punpckldq   xmm4,xmm5
    punpckhdq   xmm2,xmm5
    movdqa      xmm5,xmm0
    movdqa      xmm6,xmm1
    punpcklqdq  xmm0,xmm4
    punpckhqdq  xmm5,xmm4
    punpcklqdq  xmm1,xmm2
    punpckhqdq  xmm6,xmm2
    mov         edi,dword [esp+10h]
    movdqa      [edi],xmm0
    movdqa      [edi+10h],xmm5
    movdqa      [edi+20h],xmm1
    movdqa      [edi+30h],xmm6
    movsx       ecx,word [ebp+14h]
    movsx       edx,word [ebp+18h]
    movdqa      xmm6,[esp+80h]
    movdqa      xmm4,[esp+90h]
    movdqa      xmm5,[esp+0A0h]
    movdqa      xmm7,[esp+0B0h]
    pxor        xmm0,xmm0
    movd        xmm1,ecx
    movdqa      xmm2,xmm1
    punpcklwd   xmm2,xmm1
    pshufd      xmm1,xmm2,0
    movd        xmm2,edx
    movdqa      xmm3,xmm2
    punpcklwd   xmm3,xmm2
    pshufd      xmm2,xmm3,0
    movdqa      xmm3,xmm6
    punpckhbw   xmm6,xmm0
    movdqa      [esp+60h],xmm6
    movdqa      xmm6,[esp+90h]
    punpckhbw   xmm6,xmm0
    movdqa      [esp+30h],xmm6
    movdqa      xmm6,[esp+0A0h]
    punpckhbw   xmm6,xmm0
    movdqa      [esp+40h],xmm6
    movdqa      xmm6,[esp+0B0h]
    punpckhbw   xmm6,xmm0
    movdqa      [esp+70h],xmm6
    punpcklbw   xmm7,xmm0
    punpcklbw   xmm4,xmm0
    punpcklbw   xmm5,xmm0
    punpcklbw   xmm3,xmm0
    movdqa      [esp+50h],xmm7
    movdqa      xmm6,xmm4
    psubw       xmm6,xmm5
    pabsw       xmm6,xmm6
    movdqa      xmm0,xmm1
    pcmpgtw     xmm0,xmm6
    movdqa      xmm6,xmm3
    psubw       xmm6,xmm4
    pabsw       xmm6,xmm6
    movdqa      xmm7,xmm2
    pcmpgtw     xmm7,xmm6
    movdqa      xmm6,[esp+50h]
    psubw       xmm6,xmm5
    pabsw       xmm6,xmm6
    pand        xmm0,xmm7
    movdqa      xmm7,xmm2
    pcmpgtw     xmm7,xmm6
    movdqa      xmm6,[esp+30h]
    psubw       xmm6,[esp+40h]
    pabsw       xmm6,xmm6
    pcmpgtw     xmm1,xmm6
    movdqa      xmm6,[esp+60h]
    psubw       xmm6,[esp+30h]
    pabsw       xmm6,xmm6
    pand        xmm0,xmm7
    movdqa      xmm7,xmm2
    pcmpgtw     xmm7,xmm6
    movdqa      xmm6,[esp+70h]
    psubw       xmm6,[esp+40h]
    pabsw       xmm6,xmm6
    pand        xmm1,xmm7
    pcmpgtw     xmm2,xmm6
    pand        xmm1,xmm2
    mov         eax,2
    movsx       ecx,ax
    movd        xmm2,ecx
    movdqa      xmm6,xmm2
    punpcklwd   xmm6,xmm2
    pshufd      xmm2,xmm6,0
    movdqa      [esp+20h],xmm2
    movdqa      xmm2,xmm3
    paddw       xmm2,xmm3
    paddw       xmm2,xmm4
    paddw       xmm2,[esp+50h]
    paddw       xmm2,[esp+20h]
    psraw       xmm2,2
    movdqa      xmm6,xmm0
    pand        xmm6,xmm2
    movdqa      xmm2,xmm0
    pandn       xmm2,xmm4
    por         xmm6,xmm2
    movdqa      xmm2,[esp+60h]
    movdqa      xmm7,xmm2
    paddw       xmm7,xmm2
    paddw       xmm7,[esp+30h]
    paddw       xmm7,[esp+70h]
    paddw       xmm7,[esp+20h]
    movdqa      xmm4,xmm1
    movdqa      xmm2,xmm1
    pandn       xmm2,[esp+30h]
    psraw       xmm7,2
    pand        xmm4,xmm7
    por         xmm4,xmm2
    movdqa      xmm2,[esp+50h]
    packuswb    xmm6,xmm4
    movdqa      [esp+90h],xmm6
    movdqa      xmm6,xmm2
    paddw       xmm6,xmm2
    movdqa      xmm2,[esp+20h]
    paddw       xmm6,xmm5
    paddw       xmm6,xmm3
    movdqa      xmm4,xmm0
    pandn       xmm0,xmm5
    paddw       xmm6,xmm2
    psraw       xmm6,2
    pand        xmm4,xmm6
    por         xmm4,xmm0
    movdqa      xmm0,[esp+70h]
    movdqa      xmm5,xmm0
    paddw       xmm5,xmm0
    movdqa      xmm0,[esp+40h]
    paddw       xmm5,xmm0
    paddw       xmm5,[esp+60h]
    movdqa      xmm3,xmm1
    paddw       xmm5,xmm2
    psraw       xmm5,2
    pand        xmm3,xmm5
    pandn       xmm1,xmm0
    por         xmm3,xmm1
    packuswb    xmm4,xmm3
    movdqa      [esp+0A0h],xmm4
    mov         esi,dword [esp+10h]
    movdqa      xmm0,[esi]
    movdqa      xmm1,[esi+10h]
    movdqa      xmm2,[esi+20h]
    movdqa      xmm3,[esi+30h]
    movdqa      xmm6,xmm0
    punpcklbw   xmm0,xmm1
    punpckhbw   xmm6,xmm1
    movdqa      xmm7,xmm2
    punpcklbw   xmm2,xmm3
    punpckhbw   xmm7,xmm3
    movdqa      xmm4,xmm0
    movdqa      xmm5,xmm6
    punpcklwd   xmm0,xmm2
    punpckhwd   xmm4,xmm2
    punpcklwd   xmm6,xmm7
    punpckhwd   xmm5,xmm7
    movdqa      xmm1,xmm0
    movdqa      xmm2,xmm4
    punpckldq   xmm0,xmm6
    punpckhdq   xmm1,xmm6
    punpckldq   xmm4,xmm5
    punpckhdq   xmm2,xmm5
    movdqa      xmm5,xmm0
    movdqa      xmm6,xmm1
    punpcklqdq  xmm0,xmm4
    punpckhqdq  xmm5,xmm4
    punpcklqdq  xmm1,xmm2
    punpckhqdq  xmm6,xmm2
    mov         esi,dword [esp+1Ch]
    mov         ecx,dword [ebp+10h]
    mov         edx,dword [esp+14h]
    mov         edi,dword [esp+8]
    movd        dword [esi],xmm0
    movd        dword [esi+ecx],xmm5
    movd        dword [esi+ecx*2],xmm1
    movd        dword [esi+edx],xmm6
    psrldq      xmm0,4
    psrldq      xmm5,4
    psrldq      xmm1,4
    psrldq      xmm6,4
    mov         esi,dword [esp+18h]
    movd        dword [edi],xmm0
    movd        dword [edi+ecx],xmm5
    movd        dword [edi+ecx*2],xmm1
    movd        dword [edi+edx],xmm6
    psrldq      xmm0,4
    psrldq      xmm5,4
    psrldq      xmm1,4
    psrldq      xmm6,4
    movd        dword [esi],xmm0
    movd        dword [esi+ecx],xmm5
    movd        dword [esi+ecx*2],xmm1
    movd        dword [esi+edx],xmm6
    psrldq      xmm0,4
    psrldq      xmm5,4
    psrldq      xmm1,4
    psrldq      xmm6,4
    mov         edi,dword [esp+0Ch]
    movd        dword [edi],xmm0
    movd        dword [edi+ecx],xmm5
    movd        dword [edi+ecx*2],xmm1
    movd        dword [edi+edx],xmm6
    pop         edi
    pop         esi
    mov         esp,ebp
    pop         ebp
    ret


%endif



;********************************************************************************
;
;   void DeblockLumaTransposeH2V_sse2(uint8_t * pPixY, int32_t iStride, uint8_t * pDst);
;
;********************************************************************************

WELS_EXTERN DeblockLumaTransposeH2V_sse2
    push     r3
    push     r4
    push     r5

%assign   push_num   3
    LOAD_3_PARA
    PUSH_XMM 8

    SIGN_EXTENSION   r1, r1d

    mov      r5,    r7
    mov      r3,    r7
    and      r3,    0Fh
    sub      r7,    r3
    sub      r7,    10h

    lea      r3,    [r0 + r1 * 8]
    lea      r4,    [r1 * 3]

    movq    xmm0,  [r0]
    movq    xmm7,  [r3]
    punpcklqdq   xmm0,  xmm7
    movq    xmm1,  [r0 + r1]
    movq    xmm7,  [r3 + r1]
    punpcklqdq   xmm1,  xmm7
    movq    xmm2,  [r0 + r1*2]
    movq    xmm7,  [r3 + r1*2]
    punpcklqdq   xmm2,  xmm7
    movq    xmm3,  [r0 + r4]
    movq    xmm7,  [r3 + r4]
    punpcklqdq   xmm3,  xmm7

    lea     r0,   [r0 + r1 * 4]
    lea     r3,   [r3 + r1 * 4]
    movq    xmm4,  [r0]
    movq    xmm7,  [r3]
    punpcklqdq   xmm4,  xmm7
    movq    xmm5,  [r0 + r1]
    movq    xmm7,  [r3 + r1]
    punpcklqdq   xmm5,  xmm7
    movq    xmm6,  [r0 + r1*2]
    movq    xmm7,  [r3 + r1*2]
    punpcklqdq   xmm6,  xmm7

    movdqa  [r7],   xmm0
    movq    xmm7,  [r0 + r4]
    movq    xmm0,  [r3 + r4]
    punpcklqdq   xmm7,  xmm0
    movdqa  xmm0,   [r7]

    SSE2_TransTwo8x8B  xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7, [r7]
    ;pOut: m5, m3, m4, m8, m6, m2, m7, m1

    movdqa  [r2],    xmm4
    movdqa  [r2 + 10h],  xmm2
    movdqa  [r2 + 20h],  xmm3
    movdqa  [r2 + 30h],  xmm7
    movdqa  [r2 + 40h],  xmm5
    movdqa  [r2 + 50h],  xmm1
    movdqa  [r2 + 60h],  xmm6
    movdqa  [r2 + 70h],  xmm0

    mov     r7,   r5
    POP_XMM
    pop     r5
    pop     r4
    pop     r3
    ret


;*******************************************************************************************
;
;   void DeblockLumaTransposeV2H_sse2(uint8_t * pPixY, int32_t iStride, uint8_t * pSrc);
;
;*******************************************************************************************

WELS_EXTERN DeblockLumaTransposeV2H_sse2
    push     r3
    push     r4

%assign  push_num 2
    LOAD_3_PARA
    PUSH_XMM 8

    SIGN_EXTENSION   r1, r1d

    mov      r4,    r7
    mov      r3,    r7
    and      r3,    0Fh
    sub      r7,    r3
    sub      r7,    10h

    movdqa   xmm0,   [r2]
    movdqa   xmm1,   [r2 + 10h]
    movdqa   xmm2,   [r2 + 20h]
    movdqa   xmm3,   [r2 + 30h]
    movdqa   xmm4,   [r2 + 40h]
    movdqa   xmm5,   [r2 + 50h]
    movdqa   xmm6,   [r2 + 60h]
    movdqa   xmm7,   [r2 + 70h]

    SSE2_TransTwo8x8B  xmm0, xmm1, xmm2, xmm3, xmm4, xmm5, xmm6, xmm7, [r7]
    ;pOut: m5, m3, m4, m8, m6, m2, m7, m1

    lea      r2,   [r1 * 3]

    movq     [r0],  xmm4
    movq     [r0 + r1],  xmm2
    movq     [r0 + r1*2],  xmm3
    movq     [r0 + r2],  xmm7

    lea      r0,   [r0 + r1*4]
    movq     [r0],  xmm5
    movq     [r0 + r1],  xmm1
    movq     [r0 + r1*2],  xmm6
    movq     [r0 + r2],  xmm0

    psrldq    xmm4,   8
    psrldq    xmm2,   8
    psrldq    xmm3,   8
    psrldq    xmm7,   8
    psrldq    xmm5,   8
    psrldq    xmm1,   8
    psrldq    xmm6,   8
    psrldq    xmm0,   8

    lea       r0,  [r0 + r1*4]
    movq     [r0],  xmm4
    movq     [r0 + r1],  xmm2
    movq     [r0 + r1*2],  xmm3
    movq     [r0 + r2],  xmm7

    lea      r0,   [r0 + r1*4]
    movq     [r0],  xmm5
    movq     [r0 + r1],  xmm1
    movq     [r0 + r1*2],  xmm6
    movq     [r0 + r2],  xmm0


    mov      r7,   r4
    POP_XMM
    pop      r4
    pop      r3
    ret

WELS_EXTERN WelsNonZeroCount_sse2
    %assign  push_num 0
    LOAD_1_PARA
    movdqu  xmm0, [r0]
    movq    xmm1, [r0+16]
    WELS_DB1 xmm2
    pminub  xmm0, xmm2
    pminub  xmm1, xmm2
    movdqu  [r0], xmm0
    movq    [r0+16], xmm1
    ret
