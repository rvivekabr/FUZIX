#include <kernel.h>
#include <kdata.h>
#include <printf.h>
#include <stdbool.h>
#include <devtty.h>
#include <vt.h>
#include <tty.h>

#undef  DEBUG			/* UNdefine to delete debug code sequences */

__sfr __at 0x0C serialAd;
__sfr __at 0x0D serialAc;
__sfr __at 0x0E serialBd;
__sfr __at 0x0F serialBc;

char tbuf1[TTYSIZ];
char tbuf2[TTYSIZ];

struct s_queue ttyinq[NUM_DEV_TTY + 1] = {	/* ttyinq[0] is never used */
	{NULL, NULL, NULL, 0, 0, 0},
	{tbuf1, tbuf1, tbuf1, TTYSIZ, 0, TTYSIZ / 2},
	{tbuf2, tbuf2, tbuf2, TTYSIZ, 0, TTYSIZ / 2}
};

/* tty1 is the screen tty2 is the debug port */

/* Output for the system console (kprintf etc) */
void kputchar(char c)
{
	/* Debug port for bringup */
	if (c == '\n')
		tty_putc(2, '\r');
	tty_putc(2, c);
}

/* Both console and debug port are always ready */
bool tty_writeready(uint8_t minor)
{
	minor;
	return 1;
}

void tty_putc(uint8_t minor, unsigned char c)
{
	minor;

	if (minor == 1) {
		vtoutput(&c, 1);
		return;
	}
	serialAd = c;
}

int tty_carrier(uint8_t minor)
{
	minor;
	return 1;
}

void tty_setup(uint8_t minor)
{
	minor;
}

static uint16_t keymap[8];
static uint16_t keyin[8];
static uint8_t keybyte, keybit;
static uint8_t newkey;
static int keysdown = 0;
static uint16_t shiftmask[8] = {
	0, 0, 1, 0, 1, 0, 63, 0
};
__sfr __at 0x05 keyport;
__sfr __at 0x06 keyporth;

static void keyproc(void)
{
	int i;
	uint8_t key;

	for (i = 0; i < 8; i++) {
		/* Set the row */
		keyport = 0xff - (1 << i);
		/* Read the matrix lines - 10 bit wide */
		keyin[i] = (keyport | ((uint16_t)keyporth << 8)) ^ 0xffff;
		key = keyin[i] ^ keymap[i];
		if (key) {
			int n;
			int m = 1;
			for (n = 0; n < 10; n++) {
				if ((key & m) && (keymap[i] & m)) {
					if (!(shiftmask[i] & m))
						keysdown--;
				}
				if ((key & m) && !(keymap[i] & m)) {
					if (!(shiftmask[i] & m))
						keysdown++;
					keybyte = i;
					keybit = n;
					newkey = 1;
				}
				m += m;

			}
		}
		keymap[i] = keyin[i];
	}
}

static uint8_t keyboard[8][10] = {
	{'1', '3', '5', '7', '9' , '-', '\\', 0/*page */, 3/*brk*/, 0/*f1*/},
	{ 27, '2', '4', '6', '8', '0', '^', 0/*eol*/, 8, 0/*f5*/},
	{ 0/*ctrl*/, 'w', 'r', 'y', 'i', 'p', '[', 0/*up*/, 9, 0/*f2*/ },
	{'q', 'e', 't' , 'u', 'o', '@', 10, 8/*left*/, 127, 0 /* f6 */ },
	{ 0/*capsl*/, 's', 'f', 'h', 'k', ';', ']', 0/*right*/, 0, 0/*f7*/ },
	{ 'a', 'd', 'g', 'j', 'l', ':', 13, 12/*home*/, 0, 0 /*f3 */ },
	{ 0/*shift*/, 'x', 'v', 'n', ',', '/', 0/*shift*/, 0/*down*/,0 , 0 /*f8 */},
	{'z', 'c', 'b', 'm', '.', '_', 0/*ins*/, 0/*cls*/, ' ', 0 /* f4 */ }
};

static uint8_t shiftkeyboard[8][10] = {
	{'!', '#', '%', '\'', ')' , '=', '|', 0/*page */, 3/*brk*/, 0/*f1*/},
	{ 27, '"', '$', '&', '(', 0, '~', 0/*eol*/, 8, 0/*f5*/},
	{ 0/*ctrl*/, 'w', 'r', 'y', 'i', 'p', '{', 0/*up*/, 9, 0/*f2*/ },
	{'q', 'e', 't' , 'u', 'o', '`', 10, 8/*left*/, 127, 0 /* f6 */ },
	{ 0/*capsl*/, 's', 'f', 'h', 'k', '+', '}', 0/*right*/, 0, 0/*f7*/ },
	{ 'a', 'd', 'g', 'j', 'l', '*', 13, 12/*home*/, 0, 0 /*f3 */ },
	{ 0/*shift*/, 'x', 'v', 'n', '>', '/', 0/*shift*/, 0/*down*/,0 , 0 /*f8 */},
	{'z', 'c', 'b', 'm', '<', '_', 0/*ins*/, 0/*cls*/, ' ', 0 /* f4 */ }
};

static uint8_t capslock = 0;

static void keydecode(void)
{
	uint8_t c;

	if (keybyte == 4 && keybit == 0) {
		capslock = 1 - capslock;
		return;
	}

	if (keymap[6] & 65)	/* shift */
		c = shiftkeyboard[keybyte][keybit];
	else
		c = keyboard[keybyte][keybit];
	if (keymap[2] & 1) {	/* control */
		if (c > 31 && c < 96)
			c &= 31;
	}
	if (capslock && c >= 'a' && c <= 'z')
		c -= 'a' - 'A';
	tty_inproc(1, c);
}

void kbd_interrupt(void)
{
	newkey = 0;
	keyproc();
	if (keysdown < 3 && newkey)
		keydecode();
}

/* This is used by the vt asm code, but needs to live in the kernel */
uint16_t cursorpos;

