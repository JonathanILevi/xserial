module xserial.attribute;

import std.system : SysEndian = Endian;
import std.traits : isIntegral;

import xbuffer.varint : isVar;


// For Members
public {
	import std.meta:AliasSeq;
	alias _ForMembersUDAs = AliasSeq!(Exclude,Include,EncodeOnly,DecodeOnly,Condition,Custom);
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
	
	struct Custom(T) if(is(T == struct) || is(T == class) || is(T == interface)) { alias C = T; }
}

// For Basic Values
public {
	alias _ForBasicValuesUDAs = AliasSeq!(Endian,SysEndian,Length,NoLength);
	/**
	 * Indicates the endianness for the type and its subtypes.
	 */
	alias BigEndian = Endian.big;
	/// ditto
	alias LittleEndian = Endian.little;
	/**
	 * Encodes and decodes as a Google varint.
	 */
	alias Var = Endian.var;
	
	/**
	 * Indicates the endianness for length for the type and its subtypes.
	 */
	alias BigEndianLength = Length!(Endian.big);
	/// ditto
	alias LittleEndianLength = Length!(Endian.little);
	/**
	 * Encodes and decodes length as a Google varint.
	 */
	alias VarLength = Length!(Endian.var);
	
	/**
	 * Indicates that the array has no length. It should only be used
	 * as last field in the class/struct.
	 */
	enum NoLength;
	
	
	struct Length(T) if(isIntegral!T) {
		static alias Type = T;
		Endian endianness = cast(Endian)-1;
		this(SysEndian e) {
			endianness = cast(Endian)e;
		}
	}
	struct Length(SysEndian e) {
		static enum endianness = cast(Endian)e;
	}
	struct Length(T, SysEndian e) if(isIntegral!T) {
		static alias Type = T;
		static enum endianness = cast(Endian)e;
	}
	struct Length(SysEndian e, T) if(isIntegral!T) {
		static alias Type = T;
		static enum endianness = cast(Endian)e;
	}
	struct Length(T) if(isVar!T) {
		static alias Type = T.Base;
		static enum endianness = Endian.var;
	}
	
	alias EndianLength = Length; // for backwords compatability
	
	enum Endian : SysEndian {
		bigEndian	= SysEndian.bigEndian	,
		littleEndian	= SysEndian.littleEndian	,
		big	= bigEndian	,
		little	= littleEndian	,
		var	= cast(Endian)(little+1)	,
	}
	unittest {
		assert(Endian.big!=Endian.var);
		assert(Endian.big!=cast(Endian)-1);
	}
}

// For Objects
public {
	alias _ForObjectsUDAs = AliasSeq!(Excluder,Includer);
	/**
	 * Used for advanced addedUDAs
	 */
	struct Excluder(alias UDA_) {
		static alias UDA = UDA_;
	}
	/**
	 * Used for advanced addedUDAs
	 */
	struct Includer(alias UDA_) {
		static alias UDA = UDA_;
	}
}

