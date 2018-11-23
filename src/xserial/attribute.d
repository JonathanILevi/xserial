module xserial.attribute;

import std.system : Endian;
import std.traits : isIntegral;

import xbuffer.varint : isVar;

import xserial.serial : EndianType;

/**
 * Excludes the field from both encoding and decoding.
 */
enum Exclude;

/**
 * Includes this even if it would otherwise be excluded.
 * If Exclude (or other UDA(@)) and Include are present the last one is used, except when excluded with `@EncodeOnly` or `@DecodeOnly`.
 * Can also be used on @property methods to include them. (Be sure both the setter and getter exist!)
 * If used on a value of a base class value will be included.
 */
enum Include;

/**
 * Used for advanced addedUDAs
 */
template Excluder(alias UDA_) {
	alias UDA = UDA_;
}

/**
 * Used for advanced addedUDAs
 */
template Includer(alias UDA_) {
	alias UDA = UDA_;
}

/**
 * Excludes the field from decoding, encode only.
 * Field with be excluded in decoding regardles of any other UDA.
 */
enum EncodeOnly;
/**
 * Excludes the field from encoding, decode only.
 * Field with be excluded in encoding regardles of any other UDA.
 */
enum DecodeOnly;

/**
 * Only encode/decode the field when the condition is met.
 * The condition is placed inside an if statement and can access
 * the variables and functions of the class/struct (without `this`).
 * 
 * This attribute can be used with EncodeOnly and DecodeOnly.
 */
struct Condition { string condition; }

/**
 * Indicates the endianness for the type and its subtypes.
 */
enum BigEndian;
/// ditto
enum LittleEndian;
/**
 * Encodes and decodes as a Google varint.
 */
enum Var;

/**
 * Indicates the endianness for length for the type and its subtypes.
 */
alias BigEndianLength = Length!(EndianType.bigEndian);
/// ditto
alias LittleEndianLength = Length!(EndianType.littleEndian);
/**
 * Encodes and decodes length as a Google varint.
 */
alias VarLength = Length!(EndianType.var);

/**
 * Indicates that the array has no length. It should only be used
 * as last field in the class/struct.
 */
enum NoLength;


struct Length(T) if(isIntegral!T) {
	alias Type = T;
	EndianType endianness = cast(EndianType)-1;
	this(Endian e) {
		endianness = cast(EndianType)e;
	}
	this(EndianType e) {
		endianness = cast(EndianType)e;
	}
}

struct Length(Endian e) {
	enum endianness = cast(EndianType)e;
}
struct Length(T, Endian e) if(isIntegral!T) {
	alias Type = T;
	enum endianness = cast(EndianType)e;
}
struct Length(Endian e, T) if(isIntegral!T) {
	alias Type = T;
	enum endianness = cast(EndianType)e;
}

struct Length(EndianType e) {
	enum endianness = cast(EndianType)e;
}
struct Length(T, EndianType e) if(isIntegral!T) {
	alias Type = T;
	enum endianness = cast(EndianType)e;
}
struct Length(EndianType e, T) if(isIntegral!T) {
	alias Type = T;
	enum endianness = cast(EndianType)e;
}

struct Length(T) if(isVar!T) {
	alias Type = T.Base;
	enum endianness = EndianType.var;
}

alias EndianLength = Length;


struct Custom(T) if(is(T == struct) || is(T == class) || is(T == interface)) { alias C = T; }



