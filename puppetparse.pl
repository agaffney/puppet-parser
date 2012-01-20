#!/usr/bin/perl

use strict;
use warnings;

package PuppetParser;

use Parse::Lex;
use Data::Dumper;
use JSON;

my @keywords = (
	"case",
	"class",
	"default",
	"define",
	"import",
	"if",
	"elsif",
	"else",
	"inherits",
	"node",
	"and",
	"or",
	"undef",
	"false",
	"true",
	"in",
	"include",
);

my @tokens = (
	"LBRACK" => '\[',
	"RBRACK" => '\]',
	"LBRACE" => '\{',
	"RBRACE" => '\}',
	"LPAREN" => '\(',
	"RPAREN" => '\)',
	"FARROW" => '=>',
	"APPENDS" => '\+=',
	"ISEQUAL" => '==',
	"GREATEREQUAL" => '>=',
	"GREATERTHAN" => '>',
	"LESSTHAN" => '<',
	"LESSEQUAL" => '<=',
	"NOTEQUAL" => '!=',
	"EQUALS" => '=',
	"NOT" => '!',
	"COMMA" => ',',
	"DOT" => '\.',
	"COLON" => ':',
	"AT" => '@',
	"IN_EDGE" => '->',
	"OUT_EDGE" => '<-',
	"IN_EDGE_SUB" => '~>',
	"OUT_EDGE_SUB" => '<~',
	"LLCOLLECT" => '<<\|',
	"RRCOLLECT" => '\|>>',
	"LCOLLECT" => '<\|',
	"RCOLLECT" => '\|>',
	"SEMIC" => ';',
	"QMARK" => '\?',
	"BACKSLASH" => '\\\\',
	"PARROW" => '\+>',
	"PLUS" => '\+',
	"MINUS" => '-',
	"REGEX", '\/[^/\n]*\/',
	"DIV" => '/',
	"TIMES" => '\*',
	"LSHIFT" => '<<',
	"RSHIFT" => '>>',
	"MATCH" => '=~',
	"NOMATCH" => '!~',
	"CLASSREF" => '((::){0,1}[A-Z][-\w]*)+',
	"NUMBER", '\b(?:0[xX][0-9A-Fa-f]+|0?\d+(?:\.\d+)?(?:[eE]-?\d+)?)\b',
	"NAME", '((::)?[a-z0-9][-\w]*)(::[a-z0-9][-\w]*)*',
	new Parse::Token::Simple(Name => "COMMENT", Regex => '#.*', Sub => sub {
		my ($token, $string) = @_;
		$string =~ s/^[# ]+//;
		return $string;
	}),
	new Parse::Token::Delimited(Name => 'MLCOMMENT', Start => '/[*]', End => '[*]/' ),
#	"MLCOMMENT", qw(/\*(.*?)\*/), #m
	"RETURN", '\n',
	"DOLLAR_VAR", '\$(::)?([-\w]+::)*[-\w]+',
	"VARIABLE", '(::)?([-\w]+::)*[-\w]+',
	new Parse::Token::Quoted(Name => 'SQUOTES', Handler => 'string', Quote => "'"),
	new Parse::Token::Quoted(Name => 'DQUOTES', Handler => 'string', Escape => '\\', Quote => '"'),
	"WHITESPACE" => '\s+',
	qw(ERROR  .*), sub {
		die "unknown token: " . $_[1] . "\n";
	}
);

my @object_classes = (
	'PuppetParser::Object',
	'PuppetParser::Class',
	'PuppetParser::Resource',
);
my $default_object_class = 'PuppetParser::Object';

my @parse_patterns = (
	{
		patterns => [['RETURN']],
		func => 'parse_return',
	},
	{
		patterns => [['RBRACE']],
		func => 'parse_rbrace',
	},
	{
		patterns => [['DEFINE']],
		func => 'parse_define',
	},
	{
		patterns => [['INCLUDE']],
		func => 'parse_include',
	},
	{
		patterns => [['DOLLAR_VAR', 'EQUALS']],
		func => 'parse_var_assignment',
	},
	{
		patterns => [['CASE']],
		func => 'parse_case',
	},
	{
		patterns => [
			['SQUOTES', 'COLON', 'LBRACE'],
			['DQUOTES', 'COLON', 'LBRACE'],
			['NAME', 'COLON', 'LBRACE'],
			['REGEX', 'COLON', 'LBRACE'],
			['DEFAULT', 'COLON', 'LBRACE'],
		],
		func => 'parse_case_condition',
	},
	{
		patterns => [['COMMENT']],
		func => 'parse_comment',
	},
	{
		patterns => [['NAME', 'LBRACE']],
		func => 'parse_resource',
	},
	{
		patterns => [['NAME', 'LBRACK']],
		func => 'parse_resource_override',
	},
	{
		patterns => [['NAME', 'LPAREN']],
		func => 'parse_func_call',
	},
	{
		patterns => [
				['IF'],
				['ELSE'],
				['ELSIF'],
		],
		func => 'parse_if',
	},
);

sub new {
	my($class, $file) = @_;
	my $self = {
		file => $file,
		tree => { type => 'ROOT', contents => [] },
		parents => [],
		parent_idx => 0,
		parsed_tokens => [],
		num_parsed_tokens => 0,
		token_idx => 0,
		lexer => undef,
		buffer => '',
		indent => 0,
		obj_stack => [],
	};
	bless($self, $class);
	for(@object_classes) {
		eval "use $_;";
	}
	return $self;
}

sub object_stack {
	my ($self) = @_;
	return $self->{obj_stack};
}

sub output_json {
	my ($self, $output) = @_;
	my $json = JSON->new->pretty(1)->encode($self->{tree});
	if(defined $output && $output ne '') {
		open FOO, "> $output" or die "Could not open output file $output: $!";
		print FOO $json;
		close FOO;
	} else {
		print $json;
	}
}

sub output_puppet {
	my ($self, $output) = @_;
	my $buffer = '';
	for my $child (@{$self->{tree}->{contents}}) {
		$buffer .= $self->output_object($child);
	}
	if(defined $output && $output ne '') {
		open FOO, "> $output" or die "Could not open output file $output: $!";
		print FOO $buffer;
		close FOO;
	} else {
		print $buffer;
	}
}

sub output_object {
	my ($self, $obj, $embed) = @_;
	$embed = 0 if(!defined $embed);
#	print Dumper($obj);
	my $func_name = 'output_' . $obj->{type};
	if(PuppetParser->can($func_name)) {
		print "output_object(): calling $func_name()\n";
		return $self->$func_name($obj, $embed);
	} else {
		print "output_object(): calling output_simple() instead of $func_name()\n";
		return $self->output_simple($obj, $embed);
	}
}

sub output_simple {
	my ($self, $obj) = @_;
	my $buf = '';
	$buf .= $obj->{text};
	return $buf;
}

sub indent {
	my ($self, $level) = @_;
	if(!defined $level) {
		$level = $self->{indent};
	}
	return '  ' x $level;
}

sub newline {
	my ($self, $count) = @_;
	$count = 1 if(!defined $count);
	return "\n" x $count;
}

sub parse {
	my ($self) = @_;

	my $file = $self->{file};
	open FOO, "< $file" or die "Can't open file $file: $!";

	#Parse::Lex->trace;
	#Parse::Lex->skip('');
	$self->{lexer} = Parse::Lex->new(@tokens);
	$self->{lexer}->from(\*FOO);

	$self->read_tokens();
	while($self->cur_token()) {
		$self->parse_tokens();
		$self->next_token();
	}
}

sub transform_token_type {
	my ($self, $type, $text) = @_;
	if($type eq 'NAME') {
		if(grep(/^${text}$/, @keywords)) {
			$type = uc($text);
		}
	}
	return $type;
}

sub read_tokens {
	my ($self) = @_;
	while(1) {
		my $token = $self->{lexer}->next;
		if($self->{lexer}->eoi) {
			last;
		}
		push(@{$self->{parsed_tokens}}, { line => $self->{lexer}->line, type => $self->transform_token_type($token->name, $token->text), text => $token->text });
#		print "Type: " . $token->name . ", Text: " . $token->text . "\n";
#		print "Line: " . $self->{lexer}->line . "\n";
	}
	$self->{num_parsed_tokens} = scalar(@{$self->{parsed_tokens}});
	$self->{token_idx} = 0;
	$self->set_parent($self->{tree});
#	print "num_parsed_tokens=$num_parsed_tokens, token_idx=$token_idx\n";
}

sub cur_token {
	my ($self) = @_;
#	print "cur_token(): token_idx=" . $self->{token_idx} . "\n";
	return defined($self->{parsed_tokens}->[$self->{token_idx}]) ? $self->{parsed_tokens}->[$self->{token_idx}] : undef;
}

sub prev_token {
	my ($self) = @_;
	if($self->{token_idx} > 0) {
		$self->{token_idx}--;
	}
	return $self->cur_token();
}

sub next_token {
	my ($self) = @_;
	$self->{token_idx}++;
	return $self->cur_token();
}

sub get_token_idx {
	my ($self) = @_;
	return $self->{token_idx};
}

sub set_token_idx {
	my ($self, $idx) = @_;
	$self->{token_idx} = $idx;
}

sub get_parent {
	my ($self) = @_;
	return $self->{parents}->[$self->{parent_idx}];
}

sub set_parent {
	my ($self, $parent) = @_;
	push @{$self->{parents}}, $parent;
	$self->{parent_idx} = scalar(@{$self->{parents}}) - 1;
}

sub prev_parent {
	my ($self) = @_;
	pop @{$self->{parents}};
	$self->{parent_idx} = scalar(@{$self->{parents}}) - 1;
}

sub add_to_parent {
	my ($self, $obj) = @_;
	my $parent = $self->get_parent();
#	print "add_to_parent(): Parent idx=" . $self->{parent_idx} . ", type=" . $parent->{type} . ", children=" . scalar(@{$parent->{contents}}) . "\n";
	push @{$parent->{contents}}, $obj;
#	print Dumper($self->{tree});
}

sub max_key_length {
	my ($self, $values) = @_;
	my $max_key_len = 0;
	for my $foo (@{$values}) {
		if(length($foo->{name}) > $max_key_len) {
			$max_key_len = length($foo->{name});
		}
	}
	return $max_key_len;
}

sub parse_return {
	my ($self) = @_;
	# Just ignore it for now
	1;
}

sub parse_rbrace {
	my ($self) = @_;
	$self->prev_parent();
}

sub parse_class {
	my ($self) = @_;
	my $obj = { type => 'class', contents => [] };
	$obj->{name} = $self->next_token()->{text};
	$self->add_to_parent($obj);
	$self->next_token(); # LBRACE
	$self->set_parent($obj);
}

sub output_class {
	my ($self, $obj) = @_;
	my $buf = $self->indent() . 'class ' . $obj->{name} . ' {' . $self->newline(2);
	$self->{indent}++;
	for my $child (@{$obj->{contents}}) {
		$buf .= $self->output_object($child);
	}
	$buf .= "\n}\n";
	$self->{indent}--;
	return $buf;
}

sub parse_define {
	my ($self) = @_;
	my $obj = { type => 'define', args => [], contents => [] };
	$obj->{name} = $self->next_token()->{text};
	$self->next_token();
	while(my $token = $self->cur_token()) {
		if($token->{type} eq 'LBRACE') {
			$self->next_token();
			last;
		}
		if($token->{type} eq 'LPAREN') {
			# Beginning of arguments
			$self->next_token();
			next;
		}
		if($token->{type} eq 'RPAREN') {
			# End of arguments
			$self->next_token();
			next;
		}
		push @{$obj->{args}}, $self->parse_value(['COMMA', 'RPAREN']);
#		if($self->cur_token()->{type} eq 'RPAREN') {
#			$self->next_token();
#		}
		$self->next_token();
	}
	$self->add_to_parent($obj);
	$self->set_parent($obj);
}

sub output_define {
	my ($self, $obj) = @_;
	my $buf = $self->indent() . 'define ' . $obj->{name};
		$buf .= '(';
	if(scalar(@{$obj->{args}})) {
		my @items;
		for my $foo (@{$obj->{args}}) {
			my $tmp = '';
			for (@{$foo}) {
				if($tmp ne '') {
					$tmp .= ' ';
				}
				$tmp .= $self->output_object($_);
			}
			push @items, $tmp;
		}
		$buf .= join(', ', @items);
	}
	$buf .= ')';
	$buf .= ' {' . $self->newline();
	$self->{indent}++;
	for my $child (@{$obj->{contents}}) {
		$buf .= $self->output_object($child);
	}
	$self->{indent}--;
	$buf .= "\n" . $self->indent() . '}' . "\n";
}

sub parse_func_call {
	my ($self) = @_;
	my $cur_token = $self->cur_token();
	my $obj = { type => 'func_call', name => $cur_token->{text}, args => [] };
	$self->next_token(); # left paren
	while(1) {
		my $token = $self->next_token();
		if($token->{type} eq 'RPAREN') {
			last;
		}
		push @{$obj->{args}}, $token;
	}
	$self->add_to_parent($obj);
}

sub output_func_call {
	my ($self, $obj, $embed) = @_;
	my $buf = $embed ? '' : ($self->newline() . $self->indent());
	$buf .= $obj->{name} . '(';
	for my $arg (@{$obj->{args}}) {
		$buf .= $self->output_object($arg);
	}
	$buf .= ')' . ($embed ? '' : $self->newline());
	return $buf;
}

sub parse_include {
	my ($self) = @_;
	my $obj = { type => 'include' };
	$obj->{class} = $self->next_token()->{text};
	$self->add_to_parent($obj);
}

sub output_include {
	my ($self, $obj) = @_;
	return $self->indent() . 'include ' . $obj->{class} . $self->newline();
}

sub parse_hash {
	my ($self) = @_;
	my $obj = { type => 'hash', attribs => [] };
	$self->next_token(); # LBRACE
	while(my $token = $self->cur_token()) {
		if($token->{type} eq 'RETURN' || $token->{type} eq 'COMMENT') {
			$self->next_token();
			next;
		}
		if($self->cur_token()->{type} eq 'RBRACE') {
			last;
		}
		my $attr = { name => $token->{text} };
		$self->next_token(); # FARROW
		$self->next_token();
		$attr->{value} = $self->parse_value(['COMMA', 'SEMIC', 'RBRACE']);
		push @{$obj->{attribs}}, $attr;
		$self->next_token();
	}
	return $obj;
}

sub output_hash {
	my ($self, $obj) = @_;
	my $buf = '{' . "\n";
	$self->{indent}++;
	my $max_key_len = $self->max_key_length($obj->{attribs});
	for my $attr (@{$obj->{attribs}}) {
		$buf .= $self->indent() . sprintf("%-${max_key_len}s", $attr->{name}) . ' => ';
		#	. $self->output_object($attr->{value}) . ',' . "\n"
		my $tmp = '';
		for (@{$attr->{value}}) {
			if($tmp ne '') {
				$tmp .= ' ';
			}
			$tmp .= $self->output_object($_);
		}
		$buf .= $tmp . ',' . "\n";
	}
	$self->{indent}--;
	$buf .= $self->indent() . '}' . "\n";
	return $buf;
}

sub parse_list {
	my ($self) = @_;
	my $obj = { type => 'list', contents => [] };
	my $tmpvalue;
	$self->next_token();
	while(my $token = $self->cur_token()) {
		if($token->{type} eq 'RETURN' || $token->{type} eq 'COMMENT') {
			$self->next_token();
			next;
		}
		if($token->{type} eq 'RBRACK') {
			$self->next_token();
			last;
		}
		push @{$obj->{contents}}, $self->parse_value(['COMMA', 'RBRACK']);
		if($self->cur_token()->{type} eq 'RBRACK') {
			$self->next_token();
			last;
		}
		$self->next_token();
	}
	return $obj;
}

sub output_list {
	my ($self, $obj, $embed) = @_;
#	print Dumper($obj);
	my $buf = '[';
	$self->{indent}++;
	my $numitems = scalar(@{$obj->{contents}});
	my $split = ($numitems > 4);
	my @items;
	for my $foo (@{$obj->{contents}}) {
		my $tmp = '';
		for (@{$foo}) {
			if($tmp ne '') {
				$tmp .= ' ';
			}
			$tmp .= $self->output_object($_);
		}
		push @items, $tmp;
	}
	$buf .= ($split ? $self->newline() . $self->indent() : '' ) . join(($split ? ',' . $self->newline() . $self->indent() : ', '), @items);
	$self->{indent}--;
	$buf .= ($split ? $self->newline() . $self->indent() : '') . ']';
	return $buf;
}

sub parse_value {
	# This function advances to the next token automatically
	my ($self, $until) = @_;
	if(!defined $until) {
		$until = ['RETURN'];
	}
	my $cur_token = $self->cur_token();
	if($cur_token->{type} eq 'LBRACE') {
		# Hash
		return [ $self->parse_hash() ];
	} elsif($cur_token->{type} eq 'LBRACK') {
		# List
		return [ $self->parse_list() ];
	} else {
		if($self->match_token_sequence(['DOLLAR_VAR', 'QMARK', 'LBRACE'])) {
			# This looks like a selector
			return [ $self->parse_selector() ];
		} else {
			# This is probably just an expression
			my $tmp = [];
			TOKEN: while(my $token = $self->cur_token()) {
				for(@{$until}) {
					if($token->{type} eq $_) {
						last TOKEN;
					}
				}
				push @{$tmp}, { type => uc($token->{type}), text => $token->{text} };
				$self->next_token();
			}
			return $tmp;
		}
	}
	print "Oh noes...we fell off the end!\n";
	print "parse_value(): type=" . $cur_token->{type} . ", text=" . $cur_token->{text} . "\n";
	return undef;
}

sub parse_var_assignment {
	my ($self) = @_;
	my $cur_token = $self->cur_token();
	my $obj = { type => 'var_assignment', name => $cur_token->{text}, value => undef };
	$self->next_token(); # equals sign
	$self->next_token();
	$obj->{value} = $self->parse_value();
	$self->add_to_parent($obj);
}

sub output_var_assignment {
	my ($self, $obj) = @_;
	my $buf = "\n";
	$buf .= $self->indent() . $obj->{name} . ' = ';
	for my $foo (@{$obj->{value}}) {
		$buf .= $self->output_object($foo);
	}
	return $buf;
}

sub parse_case {
	my ($self) = @_;
	my $obj = { type => 'case', 'condition' => undef, contents => [] };
	$self->next_token();
	$obj->{condition} = $self->parse_value(['LBRACE']);
	if($self->cur_token()->{type} ne 'LBRACE') {
		print "ERROR: something went horribly wrong parsing a CASE statement\n";
		return;
	}
	$self->add_to_parent($obj);
	$self->set_parent($obj);
}

sub output_case {
	my ($self, $obj) = @_;
	my $buf = $self->newline() . $self->indent() . 'case ';
	for my $foo (@{$obj->{condition}}) {
		$buf .= $self->output_simple($foo) . ' ';
	}
	$buf .= '{' . $self->newline();
	$self->{indent}++;
	for my $child (@{$obj->{contents}}) {
		$buf .= $self->output_object($child);
	}
	$self->{indent}--;
	$buf .= $self->newline() . $self->indent() . '}' . $self->newline();
	return $buf;
}

sub parse_case_condition {
	my ($self) = @_;
	my $obj = { type => 'case_condition', condition => undef, contents => [] };
	while(my $token = $self->cur_token()) {
		if($token->{type} eq 'COLON') {
			$self->next_token();
			next;
		}
		if($token->{type} eq 'LBRACE') {
			last;
		}
		push @{$obj->{condition}}, $token;
		$self->next_token();
	}
	$self->add_to_parent($obj);
	$self->set_parent($obj);
}

sub output_case_condition {
	my ($self, $obj) = @_;
	my $buf = $self->newline() . $self->indent();
	$buf .= join(' ', map { $self->output_object($_, 1) } @{$obj->{condition}});
	$buf .= ': {' . $self->newline();
	$self->{indent}++;
        for my $child (@{$obj->{contents}}) {
		$buf .= $self->output_object($child);
	}
	$self->{indent}--;
	$buf .= $self->indent() . '}' . $self->newline();
	return $buf;
}

sub parse_comment {
	my ($self) = @_;
	my $cur_token = $self->cur_token();
	$self->add_to_parent({ type => 'comment', value => $cur_token->{text} });
}

sub output_comment {
	my ($self, $obj, $embed) = @_;
	return $self->indent() . '# ' . $obj->{value} . $self->newline();
}

sub parse_resource {
	# Is this a resource definition or an override?
	my ($self) = @_;
	my @definition_patterns = (
		['NAME', 'LBRACE', 'SQUOTES', 'COLON'],
		['NAME', 'LBRACE', 'DQUOTES', 'COLON'],
		['NAME', 'LBRACE', 'DOLLAR_VAR', 'COLON'],
		['NAME', 'LBRACE', 'LBRACK'],
	);
	for my $pattern (@definition_patterns) {
		if($self->match_token_sequence($pattern)) {
			$self->parse_resource_definition();
			return;
		}
	}
	$self->parse_resource_defaults();
}

sub parse_resource_definition {
	my ($self) = @_;
	my @key_value_patterns = (
		['NAME', 'FARROW'],
		['DQUOTES', 'FARROW'],
		['SQUOTES', 'FARROW'],
	);
	my @res_title_patterns = (
		['DOLLAR_VAR', 'COLON'],
		['SQUOTES', 'COLON'],
		['DQUOTES', 'COLON'],
		['LBRACK'],
	);
	my $cur_token = $self->cur_token();
	my $restype = $cur_token->{text};
	$self->next_token(); # LBRACE
	RES: while(1) {
		my $obj = { type => 'resource_definition', restype => $restype, title => '', attribs => [] };
		while(my $token = $self->cur_token()) {
			if($token->{type} eq 'RETURN' || $token->{type} eq 'COMMENT') {
				$self->next_token();
				next;
			}
			# Is this a key => value pair?
			for my $pattern (@key_value_patterns) {
				if($self->match_token_sequence($pattern)) {
					# This is a key => value pair
					my $attr = { name => $token->{text} };
					$self->next_token(); # FARROW
					$self->next_token();
					$attr->{value} = $self->parse_value(['COMMA', 'SEMIC', 'RBRACE']);
					push @{$obj->{attribs}}, $attr;
					if($self->cur_token()->{type} eq 'RBRACE') {
						$self->add_to_parent($obj);
						last RES;
					}
				}
			}
			# Is this a resource title?
			for my $pattern (@res_title_patterns) {
				if($self->match_token_sequence($pattern)) {
					# This is a resource title
					if($obj->{'title'} eq '') {
						if($self->match_token_sequence(['DOLLAR_VAR', 'COLON'])) {
							$obj->{title} = [ $self->cur_token() ];
							$self->next_token();
						} else {
							$obj->{title} = $self->parse_value(['COLON']);
							#$self->next_token();
						}
						next;
					} else {
						$self->add_to_parent($obj);
						next RES;
					}
				}
			}
			if($self->cur_token()->{type} eq 'RBRACE') {
				$self->add_to_parent($obj);
				last RES;
			}
			# Looking for key => value pairs
			$self->next_token();
		}
	}
}

sub output_resource_definition {
	my ($self, $obj) = @_;
	my $buf = $self->newline() . $self->indent() . $obj->{restype} . ' { ';
	my $tmp = '';
	for (@{$obj->{title}}) {
		if($tmp ne '') {
			$tmp .= ' ';
		}
		$tmp .= $self->output_object($_);
	}
	$buf .= $tmp . ':';
	if(scalar(@{$obj->{attribs}}) > 0) {
		$buf .= $self->newline();
		$self->{indent}++;
		my $max_key_len = $self->max_key_length($obj->{attribs});
		for my $attr (@{$obj->{attribs}}) {
			$buf .= $self->indent() . sprintf("%-${max_key_len}s", $attr->{name}) . ' => ';
			#	. $self->output_object($attr->{value}) . ',' . "\n"
			my $tmp = '';
			for (@{$attr->{value}}) {
				if($tmp ne '') {
					$tmp .= ' ';
				}
				$tmp .= $self->output_object($_, 1);
			}
			$buf .= $tmp . ',' . "\n";
		}
		$self->{indent}--;
		$buf .= $self->indent();
	} else {
		$buf .= ' ';
	}
	$buf .= '}' . $self->newline();
	return $buf;
}

sub parse_resource_defaults {
	my ($self) = @_;
}

sub parse_resource_override {
	my ($self) = @_;
}

sub parse_if {
	my ($self) = @_;
	my $cur_token = $self->cur_token();
	my $obj = { type => 'if', variant => lc($cur_token->{type}), condition => [], contents => [] };
	while(my $next_token = $self->next_token()) {
		if($next_token->{type} eq 'LBRACE') {
			last;
		}
		push @{$obj->{condition}}, $next_token;
	}
	$self->add_to_parent($obj);
	$self->set_parent($obj);
}

sub output_if {
	my ($self, $obj) = @_;
	my $buf = '';
	if($obj->{variant} eq 'if' || $obj->{variant} eq 'elsif') {
		$buf .= "\n" . $self->indent() . $obj->{variant} . ' ';
		for my $foo (@{$obj->{condition}}) {
			$buf .= $self->output_simple($foo) . ' ';
		}
	} elsif($obj->{variant} eq 'else') {
		$buf .= ' else';
	}
	$buf .= ' {' . "\n";
	$self->{indent}++;
	for my $child (@{$obj->{contents}}) {
		$buf .= $self->output_object($child);
	}
	$self->{indent}--;
	$buf .= "\n" . $self->indent() . '}';
	return $buf;
}

sub parse_tokens {
	my ($self) = @_;
	my $cur_parent = $self->get_parent();
	while($self->cur_token()) {
		$self->scan_for_object();
		$self->next_token();
	}
#	print Dumper($self->{tree});
#	print to_json($self->{tree});
}

sub match_token_sequence {
	my ($self, $seq, $ignore) = @_;
	if(!defined $ignore) {
		$ignore = ['RETURN', 'COMMENT', 'MLCOMMENT'];
	}
	my $orig_token = $self->get_token_idx();
	my $cur_token = $self->cur_token();
	TYPE: for my $type (@{$seq}) {
		$cur_token = $self->cur_token();
		for(@{$ignore}) {
			if($cur_token->{type} eq $_) {
				# The next token is of a type we want to ignore
				$cur_token = $self->next_token();
				next TYPE;
			}
		}
#		print "Looking for token of type: $type, Next is of type: " . $cur_token_type . ", value: " . $cur_token->{text} . "\n";
		if($cur_token->{type} ne $type) {
			$self->set_token_idx($orig_token);
			return 0;
		}
		$self->next_token();
	}
	# We found a match
	$self->set_token_idx($orig_token);
	return 1;
}

sub scan_for_object {
	my ($self) = @_;
	my $token = $self->cur_token();
	print "Line: ", $token->{line}, ", ";
	print "Type: ", $token->{type}, ", ";
	print "Content:->", $token->{text}, "<-\n";
	my $orig_token = $self->get_token_idx();
	my $cur_token = undef;
	PACKAGE: for my $package (@object_classes) {
		print "Package: $package\n";
		print Dumper($package->patterns());
		PATTERN: for my $pattern (@{$package->patterns()}) {
			print "Pattern for package ${package}:\n";
			print Dumper($pattern);
			if($self->match_token_sequence($pattern, ['RETURN'])) {
				if($package->valid($self)) {
					print "The token is valid!\n";
					return $package->new(parser => $self);
				} else {
					print "Token FAIL\n";
					next PACKAGE;
				}
			}
		}
	}
	$self->set_token_idx($orig_token);
	# We don't know how to handle this
	print "ERROR: Could not parse token\n";
}

package PuppetParser::Object;

my %defaults = (
	inner_spacing => 0,
	outer_spacing => 0,
);
my @patterns = ();

sub new {
	my ($class, %args) = @_;
	my $self = { contents => [] };
	for(keys %args) {
		$self->{$_} = $args{$_};
	}
	for(keys %defaults) {
		if(!defined $self->{$_}) {
			$self->{$_} = $defaults{$_};
		}
	}
	bless($self, $class);
	return $self;
}

sub patterns {
	return \@patterns;
}

sub add_child {
	my ($self, $child) = @_;
	push @{$self->{contents}}, $child;
}

sub get_num_children {
	my ($self) = @_;
	return scalar(@{$self->{contents}});
}

sub get_child {
	my ($self, $idx) = @_;
	return $self->{contents}->[$idx];
}

sub get_prev_child {
	my ($self) = @_;
	return $self->get_child($self->get_num_children() - 2);
}

sub indent {
	my ($self, $additional) = @_;
	my $level = scalar(@{$self->{parser}->object_stack()}) - 1;
	if(defined $additional) {
		$level += $additional;
	}
	return '  ' x $level;
}

sub valid {
	return 1;
}

sub output {
	# This is a shell for simple objects. This will be overriden in more complex types
	my ($self) = @_;
	return defined $self->{text} ? $self->{text} : '';
}

package PuppetParser::Class;

use Data::Dumper;

our @ISA = 'PuppetParser::Object';
our %defaults = (
	inner_spacing => 1,
	outer_spacing => 1,
);
our @patterns = (
	['CLASS'],
);

sub new {
	print "constructor for PuppetParser::Class\n";
	my $type = shift;
	my $class = ref $type || $type;
	my $self = $class->SUPER::new(@_);
	print Dumper($self);
	return $self;
}

sub patterns {
	return \@patterns;
}

sub output {
	my ($self) = @_;
	my $buf = $self->indent() . $self->{text};
	return $buf;
}

sub valid {
	return 1;
}

package PuppetParser::Resource;

our @ISA = 'PuppetParser::Object';
our @patterns = (
);


package main;

use Getopt::Std;

# Flags
my %options;
my $output = '';
my $json = 0;

# Parse options
my $result = getopts('jo:', \%options);
if(defined $options{'o'}) {
	$output = $options{'o'};
}
if(defined $options{'j'}) {
	$json = $options{'j'};
}
my $file = shift;

print "Parsing $file\n";
my $parser = PuppetParser->new($file);
$parser->parse();

if($json) {
	$parser->output_json($output);
} else {
	$parser->output_puppet($output);
}
