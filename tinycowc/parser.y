%include
{
    #include <stdlib.h>
    #include <stdio.h>
    #include <stdarg.h>
    #include <string.h>
    #include "globals.h"
    #include "midcode.h"
    #include "parser.h"
	#include "compiler.h"

    int current_label = 1;

    static int break_label;

	#undef NDEBUG
}

%token AMPERSAND AND AS ASM ASSIGN BREAK CLOSEPAREN CLOSESQ.
%token COLON COMMA CONST DOT ELSE END EQOP EXTERN GEOP GTOP.
%token IF LEOP LOOP LTOP MINUS NEOP NOT OPENPAREN OPENSQ.
%token OR PERCENT PIPE PLUS RECORD RETURN SEMICOLON SLASH STAR.
%token SUB THEN TILDE VAR WHILE TYPE.

%left COMMA.
%left OR.
%left AND.
%left AS.
%left PIPE.
%left CARET.
%left AMPERSAND.
%left LTOP LEOP GTOP GEOP EQOP NEOP.
%left PLUS MINUS.
%left STAR SLASH PERCENT.
%right NOT.

%token_type {struct token*}
%type typeref {struct symbol*}
%type expression {struct symbol*}
%type lvalue {struct symbol*}

%syntax_error {
    fatal("syntax error: unexpected %s", yyTokenName[yymajor]);
}
%stack_overflow {
    fatal("stack overflow");
}

%token_destructor
{
	free_token($$);
}

program ::= statements.

statements ::= /* empty */.
statements ::= statement statements.

/* --- Top-level statements ---------------------------------------------- */

statement ::= SEMICOLON.

/* --- Variable declaration ---------------------------------------------- */

statement ::= typedvardecl SEMICOLON.

statement ::= typedvardecl(V) ASSIGN expression(E) SEMICOLON.
{
    init_var(V, V->u.var.type);
    check_expression_type(&E, V->u.var.type);
    emit_mid_store(E->u.type.width);
}

statement ::= untypedvardecl(V) ASSIGN expression(E) SEMICOLON.
{
	if (!E)
		fatal("types cannot be inferred for numeric constants");
	init_var(V, E);
	check_expression_type(&E, E);
	emit_mid_store(E->u.type.width);
}

%type typedvardecl {struct symbol*}
typedvardecl(V) ::= VAR newid(S) COLON typeref(T).
{
    S->kind = VAR;
    init_var(S, T);
	V = S;
}

%type untypedvardecl {struct symbol*}
untypedvardecl(T) ::= VAR newid(S).
{
	S->kind = VAR;
	emit_mid_address(S);
	T = S;
}

/* --- Control flow ------------------------------------------------------ */

statement ::= startloopstatement(labels) statements END LOOP.
{
	emit_mid_jump(labels.looplabel);
	emit_mid_label(labels.exitlabel);
	break_label = labels.old_break_label;
}

%type startloopstatement {struct looplabels}
startloopstatement(labels) ::= LOOP.
{
	labels.looplabel = current_label++;
	labels.exitlabel = current_label++;
	labels.old_break_label = break_label;
	break_label = labels.exitlabel;
	emit_mid_label(labels.looplabel);
}

/* --- Subroutines ------------------------------------------------------- */

statement ::= EXTERN startsubroutine(oldsub) parameterlist
	ASSIGN STRING(nametoken) SEMICOLON.
{
	current_sub->externname = strdup(nametoken->string);

	break_label = current_sub->old_break_label;
	current_sub = oldsub;
}

/* Remember the value of this is the *old* subroutine. */
%type startsubroutine {struct subroutine*}
startsubroutine(oldsub) ::= SUB newid(sym).
{
	oldsub = current_sub;

	struct subroutine* sub = calloc(1, sizeof(struct subroutine));
	sub->name = sym->name;
	sub->namespace.parent = &current_sub->namespace;
	arch_init_subroutine(sub);
	break_label = 0;

	sym->kind = SUB;
	sym->u.sub = sub;

	current_sub = sub;
}

statement ::= startrealsubroutine(oldsub) statements END SUB.
{
	emit_mid_endsub(current_sub);
	break_label = current_sub->old_break_label;
	current_sub = oldsub;
}

/* Remember the value of this is the *old* subroutine. */
%type startrealsubroutine {struct subroutine*}
startrealsubroutine(oldsubout) ::= startsubroutine(oldsubin) parameterlist.
{
	oldsubout = oldsubin;
	emit_mid_startsub(current_sub);
}

parameterlist ::= OPENPAREN CLOSEPAREN.
parameterlist ::= OPENPAREN parameters CLOSEPAREN.
parameters ::= parameter.
parameters ::= parameter COMMA parameters.

parameter ::= newid(id) COLON typeref(type).
{
	id->kind = VAR;
	init_var(id, type);
	current_sub->inputparameters++;
}

/* --- Constant expressions ---------------------------------------------- */

%type cvalue {int32_t}
cvalue(value) ::= NUMBER(token).                   { value = token->number; }
cvalue(value) ::= OPENPAREN cvalue(v) CLOSEPAREN.  { value = v; }
cvalue(value) ::= MINUS cvalue(v).                 { value = -v; }
cvalue(value) ::= cvalue(lhs) PLUS cvalue(rhs).    { value = lhs + rhs; }
cvalue(value) ::= cvalue(lhs) MINUS cvalue(rhs).   { value = lhs - rhs; }
cvalue(value) ::= cvalue(lhs) STAR cvalue(rhs).    { value = lhs * rhs; }
cvalue(value) ::= cvalue(lhs) PERCENT cvalue(rhs). { value = lhs % rhs; }

cvalue(value) ::= oldid(sym).
{
	if (sym->kind != CONST)
		fatal("only constants can be used here");
	value = sym->u.constant;
}
/* --- Expressions ------------------------------------------------------- */

expression(T) ::= NUMBER(NUMBER).
{
	emit_mid_constant(NUMBER);
	T = NULL;
}

expression(T) ::= lvalue(T1).
{
	if (T1)
	{
		emit_mid_load(T1->u.type.element->u.type.width);
		T = T1->u.type.element;
	}
	else
		T = NULL;
}

expression(T) ::= AMPERSAND lvalue(T1).
{
	if (!T1)
		fatal("you cannot take the address of an untyped constant");
	T = T1;
}

expression(T) ::= MINUS expression(T1).                    { T = T1; emit_mid_neg(T1 ? T1->u.type.width : 0); }
expression(T) ::= OPENPAREN expression(T1) CLOSEPAREN.     { T = T1; }
expression(T) ::= expression(T1) PLUS expression(T2).      { T = expr_add(T1, T2); }
expression(T) ::= expression(T1) MINUS expression(T2).     { T = expr_sub(T1, T2); }
expression(T) ::= expression(T1) STAR expression(T2).      { T = expr_simple(T1, T2, emit_mid_mul); }
expression(T) ::= expression(T1) SLASH expression(T2).     { T = expr_signed(T1, T2, emit_mid_divu, emit_mid_divs); }
expression(T) ::= expression(T1) PERCENT expression(T2).   { T = expr_signed(T1, T2, emit_mid_remu, emit_mid_rems); }
expression(T) ::= expression(T1) CARET expression(T2).     { T = expr_simple(T1, T2, emit_mid_eor); }
expression(T) ::= expression(T1) AMPERSAND expression(T2). { T = expr_simple(T1, T2, emit_mid_and); }
expression(T) ::= expression(T1) PIPE expression(T2).      { T = expr_simple(T1, T2, emit_mid_or); }

lvalue(T) ::= oldid(S).
{
	if (S->kind == CONST)
	{
		emit_mid_constant(S->u.constant);
		T = NULL;
	}
	else
	{
		emit_mid_address(S);
		T = make_pointer_type(S->u.var.type);
	}
}

lvalue(T) ::= OPENSQ expression(T1) CLOSESQ.
{
	if (!is_ptr(T1))
		fatal("cannot dereference non-pointers");
	T = T1;
}

%type newid {struct symbol*}
newid(S) ::= ID(token).
{
    S = add_new_symbol(NULL, token->string);
}

%type oldid {struct symbol*}
oldid(S) ::= ID(token).
{
    S = lookup_symbol(NULL, token->string);
}

/* --- Types ------------------------------------------------------------- */

typeref(sym) ::= oldid(id).
{
    sym = id;
    if (sym->kind != TYPE)
        fatal("expected '%s' to be a type", sym->name);
}

typeref(sym) ::= typeref(basetype) OPENSQ cvalue(value) CLOSESQ.
{
	sym = make_array_type(basetype, value);
}

typeref(sym) ::= OPENSQ typeref(basetype) CLOSESQ.
{
	sym = make_pointer_type(basetype);
}

/* --- Inline assembly --------------------------------------------------- */

statement ::= asmstart asms SEMICOLON.
{
	emit_mid_asmend();
}

asmstart ::= ASM.
{
	emit_mid_asmstart();
}

asms ::= asm.
asms ::= asm COMMA asms.

asm ::= STRING(token).
{
	unescape(token->string);
	emit_mid_asmtext(strdup(token->string));
}

asm ::= oldid(ID).
{
	if (ID->kind != VAR)
		fatal("you can only emit references to variables");
	emit_mid_asmsymbol(ID);
}
