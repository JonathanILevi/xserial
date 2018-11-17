module xserial.serial;

import std.system : Endian, endian;
import std.traits : isArray, isDynamicArray, isStaticArray, isAssociativeArray, ForeachType, KeyType, ValueType, isIntegral, isFloatingPoint, isSomeChar, isType, isCallable, isPointer, hasUDA, getUDAs, TemplateOf;
import std.typecons : isTuple;
import std.algorithm.searching : canFind;
import std.meta : AliasSeq;

import xbuffer.buffer : canSwapEndianness, Buffer, BufferOverflowException;
import xbuffer.memory : xalloc, xfree;
import xbuffer.varint : isVar;

import xserial.attribute;

/**
 * Serializes some data.
 */
ubyte[] serialize(Endian endianness=endian, L=uint, Endian lengthEndianness=endianness, T)(T value, Buffer buffer) {
	return Grouped!().serialize!(endianness, L, lengthEndianness)(value,buffer);
}
/// ditto
ubyte[] serialize(Endian endianness=endian, L=uint, Endian lengthEndianness=endianness, T)(T value) {
	return Grouped!().serialize!(endianness, L, lengthEndianness)(value);
}
/**
 * Deserializes some data.
 */
T deserialize(T, Endian endianness=endian, L=uint, Endian lengthEndianness=endianness)(Buffer buffer) {
	return Grouped!().deserialize!(T, endianness, L, lengthEndianness)(buffer);
}
/// ditto
T deserialize(T, Endian endianness=endian, L=uint, Endian lengthEndianness=endianness)(in ubyte[] data) {
	return Grouped!().deserialize!(T, endianness, L, lengthEndianness)(data);
}
 template Grouped(AddedUDAs...) {
	/**
	 * Serializes some data.
	 */
	ubyte[] serialize(Endian endianness=endian, L=uint, Endian lengthEndianness=endianness, T)(T value, Buffer buffer) {
		serializeImpl!(endianness, L, lengthEndianness, T, AddedUDAs)(buffer, value);
		return buffer.data!ubyte;
	}
	/// ditto
	ubyte[] serialize(Endian endianness=endian, L=uint, Endian lengthEndianness=endianness, T)(T value) {
		Buffer buffer = xalloc!Buffer(64);
		scope(exit) xfree(buffer);
		return Grouped!AddedUDAs.serialize!(endianness, L, lengthEndianness, T)(value, buffer).dup;
	}
	/**
	 * Deserializes some data.
	 */
	T deserialize(T, Endian endianness=endian, L=uint, Endian lengthEndianness=endianness)(Buffer buffer) {
		return deserializeImpl!(endianness, L, lengthEndianness, T, AddedUDAs)(buffer);
	}
	/// ditto
	T deserialize(T, Endian endianness=endian, L=uint, Endian lengthEndianness=endianness)(in ubyte[] data) {
		Buffer buffer = xalloc!Buffer(data);
		scope(exit) xfree(buffer);
		return Grouped!AddedUDAs.deserialize!(T, endianness, L, lengthEndianness)(buffer);
	}
}


// -----------
// common data
// -----------

enum EndianType {
	
	bigEndian = cast(int)Endian.bigEndian,
	littleEndian = cast(int)Endian.littleEndian,
	var,
	
}

/**
 * Copied and slightly modified from Phobos `std.traits`. (dlang.org/phobos/std_traits.html)
 */
private template isDesiredUDA(alias attribute, alias toCheck)
{
    static if (is(typeof(attribute)) && !__traits(isTemplate, attribute))
    {
        static if (__traits(compiles, toCheck == attribute))
            enum isDesiredUDA = toCheck == attribute;
        else
            enum isDesiredUDA = false;
    }
    else static if (is(typeof(toCheck)))
    {
        static if (__traits(isTemplate, attribute))
            enum isDesiredUDA =  isInstanceOf!(attribute, typeof(toCheck));
        else
            enum isDesiredUDA = is(typeof(toCheck) == attribute);
    }
    else static if (__traits(isTemplate, attribute))
        enum isDesiredUDA = isInstanceOf!(attribute, toCheck);
    else
        enum isDesiredUDA = is(toCheck == attribute);
}

auto getSerializeMembers(T, Only, AddedUDAs...)() {
	alias UDAs = AliasSeq!(AddedUDAs,Includer!Include,Excluder!Exclude);
	
	struct Member{
		string name	;
		string condition	="";
	}
	
	Member[] members;
	
	foreach(member; __traits(allMembers, T)) {
		string condition = "";
		static if(!hasUDA!(__traits(getMember, T, member), Only)) {
			static foreach_reverse (Attribute; __traits(getAttributes, __traits(getMember, T, member))) {
				static if (!is(typeof(done))) {
					static if(is(typeof(Attribute)==Condition)) {
						members ~= Member(member, Attribute.condition);
						enum done = true;
					}
					else static foreach(A;UDAs) {
						static if (!is(typeof(done))) {
							static if(isDesiredUDA!(Attribute,A.UDA)) {
								static if (__traits(isSame,TemplateOf!A,Includer)) {
									members ~= Member(member);
								}
								else static assert(__traits(isSame,TemplateOf!A,Excluder), "AddedUDA is not a template of Include or Exclude");
								enum done = true;
							}
						}
					}
				}
			}
			static if (!is(typeof(done))) {
				static if(is(typeof(mixin("T." ~ member)))) {
					mixin("alias M = typeof(T." ~ member ~ ");");
					static if(
						isType!M &&
						!isCallable!M &&
						!__traits(compiles, { mixin("auto test=T." ~ member ~ ";"); }) &&   // static members
						!__traits(compiles, { mixin("auto test=T.init." ~ member ~ "();"); }) // properties
						) {
						members ~= Member(member);
					}
				}
			}
		}
	}
	
	return members;
}

// -------------
// serialization
// -------------

void serializeImpl(Endian endianness, L, Endian lengthEndianness, T, AddedUDAs...)(Buffer buffer, T value) {
	static if(isVar!L) serializeImpl!(cast(EndianType)endianness, L.Type, EndianType.var, L.Type, EndianType.var, T, AddedUDAs)(buffer, value);
	else serializeImpl!(cast(EndianType)endianness, L, cast(EndianType)lengthEndianness, L, cast(EndianType)lengthEndianness, T, AddedUDAs)(buffer, value);
}

void serializeImpl(EndianType endianness, OL, EndianType ole, CL, EndianType cle, T, AddedUDAs...)(Buffer buffer, T value) {
	static if(isArray!T) {
		static if(isDynamicArray!T) serializeLength!(cle, CL)(buffer, value.length);
		serializeArray!(endianness, OL, ole, AddedUDAs)(buffer, value);
	} else static if(isAssociativeArray!T) {
		serializeLength!(cle, CL)(buffer, value.length);
		serializeAssociativeArray!(endianness, OL, ole, AddedUDAs)(buffer, value);
	} else static if(isTuple!T) {
		serializeTuple!(endianness, OL, ole)(buffer, value);
	} else static if(is(T == class) || is(T == struct) || is(T == interface)) {
		static if(__traits(hasMember, T, "serialize") && __traits(compiles, value.serialize(buffer))) {
			value.serialize(buffer);
		} else {
			serializeMembers!(endianness, OL, ole, T, AddedUDAs)(buffer, value);
		}
	} else static if(is(T : bool) || isIntegral!T || isFloatingPoint!T || isSomeChar!T) {
		serializeNumber!endianness(buffer, value);
	} else {
		static assert(0, "Cannot serialize " ~ T.stringof);
	}
}

void serializeNumber(EndianType endianness, T)(Buffer buffer, T value) {
	static if(endianness == EndianType.var) {
		static assert(isIntegral!T && T.sizeof > 1, T.stringof ~ " cannot be annotated with @Var");
		buffer.writeVar!T(value);
	} else static if(endianness == EndianType.bigEndian) {
		buffer.write!(Endian.bigEndian, T)(value);
	} else static if(endianness == EndianType.littleEndian) {
		buffer.write!(Endian.littleEndian, T)(value);
	}
}

void serializeLength(EndianType endianness, L)(Buffer buffer, size_t length) {
	static if(L.sizeof < size_t.sizeof) serializeNumber!(endianness, L)(buffer, cast(L)length);
	else serializeNumber!(endianness, L)(buffer, length);
}

void serializeArray(EndianType endianness, OL, EndianType ole, T, AddedUDAs...)(Buffer buffer, T array) if(isArray!T) {
	static if(canSwapEndianness!(ForeachType!T) && !is(ForeachType!T == struct) && !is(ForeachType!T == class) && endianness != EndianType.var) {
		buffer.write!(cast(Endian)endianness)(array);
	} else {
		foreach(value ; array) {
			serializeImpl!(endianness, OL, ole, OL, ole, AddedUDAs)(buffer, value);
		}
	}
}

void serializeAssociativeArray(EndianType endianness, OL, EndianType ole, T, AddedUDAs...)(Buffer buffer, T array) if(isAssociativeArray!T) {
	foreach(key, value; array) {
		serializeImpl!(endianness, OL, ole, OL, ole, AddedUDAs)(buffer, key);
		serializeImpl!(endianness, OL, ole, OL, ole, AddedUDAs)(buffer, value);
	}
}

void serializeTuple(EndianType endianness, OL, EndianType ole, T, AddedUDAs...)(Buffer buffer, T tuple) if(isTuple!T) {
	static foreach(i ; 0..tuple.fieldNames.length) {
		serializeImpl!(endianness, OL, ole, OL, ole)(buffer, tuple[i]);
	}
}

void serializeMembers(EndianType endianness, L, EndianType le, T, AddedUDAs...)(Buffer __buffer, T __container) {
	enum serMems = getSerializeMembers!(T, DecodeOnly, AddedUDAs);
	static foreach(member; serMems) {{
		
		mixin("alias M = typeof(__container." ~ member.name ~ ");");
		
		static foreach(uda ; __traits(getAttributes, __traits(getMember, T, member.name))) {
			static if(is(uda : Custom!C, C)) {
				enum __custom = true;
				uda.C.serialize(mixin("__container." ~ member.name), __buffer);
			}
		}
		
		static if(!is(typeof(__custom))) 
		mixin(
		{
				
			static if(hasUDA!(__traits(getMember, T, member.name), LengthImpl)) {
				import std.conv : to;
				auto length = getUDAs!(__traits(getMember, T, member.name), LengthImpl)[0];
				immutable e = "L, le, " ~ length.type ~ ", " ~ (length.endianness == -1 ? "endianness" : "EndianType." ~ (cast(EndianType)length.endianness).to!string);
			} else {
				immutable e = "L, le, L, le";
			}
			
			static if(hasUDA!(__traits(getMember, T, member.name), NoLength)) immutable ret = "xserial.serial.serializeArray!(endianness, L, le, M, AddedUDAs)(__buffer, __container." ~ member.name ~ ");";
			else static if(hasUDA!(__traits(getMember, T, member.name), Var)) immutable ret = "xserial.serial.serializeImpl!(EndianType.var, " ~ e ~ ", M, AddedUDAs)(__buffer, __container." ~ member.name ~ ");";
			else static if(hasUDA!(__traits(getMember, T, member.name), BigEndian)) immutable ret = "xserial.serial.serializeImpl!(EndianType.bigEndian, " ~ e ~ ", M, AddedUDAs)(__buffer, __container." ~ member.name ~ ");";
			else static if(hasUDA!(__traits(getMember, T, member.name), LittleEndian)) immutable ret = "xserial.serial.serializeImpl!(EndianType.littleEndian, " ~ e ~ ", M, AddedUDAs)(__buffer, __container." ~ member.name ~ ");";
			else immutable ret = "xserial.serial.serializeImpl!(endianness, " ~ e ~ ", M, AddedUDAs)(__buffer, __container." ~ member.name ~ ");";
			
			if (member.condition.length==0) return ret;
			else return "with(__container){if(" ~ member.condition ~ "){" ~ ret ~ "}}";
			
		}
		()
		);
		
	}}
}

// ---------------
// deserialization
// ---------------

T deserializeImpl(Endian endianness, L, Endian lengthEndianness, T, AddedUDAs...)(Buffer buffer) {
	static if(isVar!L) return deserializeImpl!(cast(EndianType)endianness, L.Type, EndianType.var, L.Type, EndianType.var, T, AddedUDAs)(buffer);
	else return deserializeImpl!(cast(EndianType)endianness, L, cast(EndianType)lengthEndianness, L, cast(EndianType)lengthEndianness, T, AddedUDAs)(buffer);
}

T deserializeImpl(EndianType endianness, OL, EndianType ole, CL, EndianType cle, T, AddedUDAs...)(Buffer buffer) {
	static if(isStaticArray!T) {
		return deserializeStaticArray!(endianness, OL, ole, T, AddedUDAs)(buffer);
	} else static if(isDynamicArray!T) {
		return deserializeDynamicArray!(endianness, OL, ole, T, AddedUDAs)(buffer, deserializeLength!(cle, CL)(buffer));
	} else static if(isAssociativeArray!T) {
		return deserializeAssociativeArray!(endianness, OL, ole, T, AddedUDAs)(buffer, deserializeLength!(cle, CL)(buffer));
	} else static if(isTuple!T) {
		return deserializeTuple!(endianness, OL, ole, T, AddedUDAs)(buffer);
	} else static if(is(T == class) || is(T == struct)) {
		T ret;
		static if(is(T == class)) ret = new T();
		static if(__traits(hasMember, T, "deserialize") && __traits(compiles, ret.deserialize(buffer))) {
			ret.deserialize(buffer);
		} else {
			deserializeMembers!(endianness, OL, ole, T*, AddedUDAs)(buffer, &ret);
		}
		return ret;
	} else static if(is(T : bool) || isIntegral!T || isFloatingPoint!T || isSomeChar!T) {
		return deserializeNumber!(endianness, T)(buffer);
	} else {
		static assert(0, "Cannot deserialize " ~ T.stringof);
	}
}

T deserializeNumber(EndianType endianness, T)(Buffer buffer) {
	static if(endianness == EndianType.var) {
		static assert(isIntegral!T && T.sizeof > 1, T.stringof ~ " cannot be annotated with @Var");
		return buffer.readVar!T();
	} else static if(endianness == EndianType.bigEndian) {
		return buffer.read!(Endian.bigEndian, T)();
	} else static if(endianness == EndianType.littleEndian) {
		return buffer.read!(Endian.littleEndian, T)();
	}
}

size_t deserializeLength(EndianType endianness, L)(Buffer buffer) {
	static if(L.sizeof > size_t.sizeof) return cast(size_t)deserializeNumber!(endianness, L)(buffer);
	else return deserializeNumber!(endianness, L)(buffer);
}

T deserializeStaticArray(EndianType endianness, OL, EndianType ole, T, AddedUDAs...)(Buffer buffer) if(isStaticArray!T) {
	T ret;
	foreach(ref value ; ret) {
		value = deserializeImpl!(endianness, OL, ole, OL, ole, ForeachType!T, AddedUDAs)(buffer);
	}
	return ret;
}

T deserializeDynamicArray(EndianType endianness, OL, EndianType ole, T, AddedUDAs...)(Buffer buffer, size_t length) if(isDynamicArray!T) {
	T ret;
	foreach(i ; 0..length) {
		ret ~= deserializeImpl!(endianness, OL, ole, OL, ole, ForeachType!T, AddedUDAs)(buffer);
	}
	return ret;
}

T deserializeAssociativeArray(EndianType endianness, OL, EndianType ole, T, AddedUDAs...)(Buffer buffer, size_t length) if(isAssociativeArray!T) {
	T ret;
	foreach(i ; 0..length) {
		ret[deserializeImpl!(endianness, OL, ole, OL, ole, KeyType!T, AddedUDAs)(buffer)] = deserializeImpl!(endianness, OL, ole, OL, ole, ValueType!T)(buffer);
	}
	return ret;
}

T deserializeNoLengthArray(EndianType endianness, OL, EndianType ole, T, AddedUDAs...)(Buffer buffer) if(isDynamicArray!T) {
	T ret;
	try {
		while(true) ret ~= deserializeImpl!(endianness, OL, ole, OL, ole, ForeachType!T, AddedUDAs)(buffer);
	} catch(BufferOverflowException) {}
	return ret;
}

T deserializeTuple(EndianType endianness, OL, EndianType ole, T, AddedUDAs...)(Buffer buffer) if(isTuple!T) {
	T ret;
	foreach(i, U; T.Types) {
		ret[i] = deserializeImpl!(endianness, OL, ole, OL, ole, U, AddedUDAs)(buffer);
	}
	return ret;
}

void deserializeMembers(EndianType endianness, L, EndianType le, C, AddedUDAs...)(Buffer __buffer, C __container) {
	static if(isPointer!C) alias T = typeof(*__container);
	else alias T = C;
	
	enum serMems = getSerializeMembers!(T, EncodeOnly, AddedUDAs);
	static foreach(member; serMems) {{
		
		mixin("alias M = typeof(__container." ~ member.name ~ ");");
		
		static foreach(uda ; __traits(getAttributes, __traits(getMember, T, member.name))) {
			static if(is(uda : Custom!C, C)) {
				enum __custom = true;
				mixin("__container." ~ member.name) = uda.C.deserialize(__buffer);
			}
		}
		
		static if(!is(typeof(__custom))) mixin({
				
			static if(hasUDA!(__traits(getMember, T, member.name), LengthImpl)) {
				import std.conv : to;
				auto length = getUDAs!(__traits(getMember, T, member.name), LengthImpl)[0];
				immutable e = "L, le, " ~ length.type ~ ", " ~ (length.endianness == -1 ? "endianness" : "EndianType." ~ (cast(EndianType)length.endianness).to!string);
			} else {
				immutable e = "L, le, L, le";
			}
			
			static if(hasUDA!(__traits(getMember, T, member.name), NoLength)) immutable ret = "__container." ~ member.name ~ "=xserial.serial.deserializeNoLengthArray!(endianness, L, le, M, AddedUDAs)(__buffer);";
			else static if(hasUDA!(__traits(getMember, T, member.name), Var)) immutable ret = "__container." ~ member.name ~ "=xserial.serial.deserializeImpl!(EndianType.var, " ~ e ~ ", M, AddedUDAs)(__buffer);";
			else static if(hasUDA!(__traits(getMember, T, member.name), BigEndian)) immutable ret = "__container." ~ member.name ~ "=xserial.serial.deserializeImpl!(EndianType.bigEndian, " ~ e ~ ", M, AddedUDAs)(__buffer);";
			else static if(hasUDA!(__traits(getMember, T, member.name), LittleEndian)) immutable ret = "__container." ~ member.name ~ "=xserial.serial.deserializeImpl!(EndianType.littleEndian, " ~ e ~ ", M, AddedUDAs)(__buffer);";
			else immutable ret = "__container." ~ member.name ~ "=xserial.serial.deserializeImpl!(endianness, " ~ e ~ ", M, AddedUDAs)(__buffer);";
			
			if (member.condition.length==0) return ret;
			else return "with(__container){if(" ~ member.condition ~ "){" ~ ret ~ "}}";
			
		}());
		
	}}
}

// ---------
// unittests
// ---------

@("numbers") unittest {

	// bools and numbers
	
	assert(true.serialize() == [1]);
	assert(5.serialize!(Endian.bigEndian)() == [0, 0, 0, 5]);
	
	assert(deserialize!(int, Endian.bigEndian)([0, 0, 0, 5]) == 5);

	version(LittleEndian) assert(12.serialize() == [12, 0, 0, 0]);
	version(BigEndian) assert(12.serialize() == [0, 0, 0, 12]);

}

@("arrays") unittest {

	assert([1, 2, 3].serialize!(Endian.bigEndian, uint)() == [0, 0, 0, 3, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3]);
	assert([1, 2, 3].serialize().deserialize!(int[])() == [1, 2, 3]);

	ushort[2] test1 = [1, 2];
	assert(test1.serialize!(Endian.bigEndian)() == [0, 1, 0, 2]);
	test1 = deserialize!(ushort[2], Endian.littleEndian)([2, 0, 1, 0]);
	assert(test1 == [2, 1]);

}

@("associative arrays") unittest {

	// associative arrays

	int[ushort] test;
	test[1] = 112;
	assert(test.serialize!(Endian.bigEndian, uint)() == [0, 0, 0, 1, 0, 1, 0, 0, 0, 112]);

	test = deserialize!(int[ushort], Endian.bigEndian, ubyte)([1, 0, 0, 0, 0, 0, 55]);
	assert(test == [ushort(0): 55]);

}

@("tuples") unittest {

	import std.typecons : Tuple, tuple;

	assert(tuple(1, "test").serialize!(Endian.bigEndian, ushort)() == [0, 0, 0, 1, 0, 4, 't', 'e', 's', 't']);

	Tuple!(ubyte, "a", uint[], "b") test;
	test.a = 12;
	assert(test.serialize!(Endian.littleEndian, uint)() == [12, 0, 0, 0, 0]);
	assert(deserialize!(typeof(test), Endian.bigEndian, ushort)([12, 0, 0]) == test);

}

@("structs and classes") unittest {

	struct Test1 {

		byte a, b, c;

	}

	Test1 test1 = Test1(1, 3, 55);
	assert(test1.serialize() == [1, 3, 55]);

	assert(deserialize!Test1([1, 3, 55]) == test1);

	static struct Test2 {

		int a;

		void serialize(Buffer buffer) {
			buffer.write!(Endian.bigEndian)(this.a + 1);
		}

		void deserialize(Buffer buffer) {
			this.a = buffer.read!(Endian.bigEndian, int)() - 1;
		}

	}

	assert(serialize(Test2(5)) == [0, 0, 0, 6]);
	assert(deserialize!Test2([0, 0, 0, 6]) == Test2(5));

	static class Test3 {

		ubyte a;

		void serialize() {}

		void deserialize() {}

	}

	Test3 test3 = new Test3();
	assert(serialize(test3) == [0]);
	assert(deserialize!Test3([5]).a == 5);

}

@("attributes") unittest {

	struct Test1 {

		@BigEndian int a;

		@EncodeOnly @LittleEndian ushort b;

		@Condition("a==1") @Var uint c;

		@DecodeOnly @Var uint d;

		@Exclude ubyte e;

	}

	Test1 test1 = Test1(1, 2, 3, 4, 5);
	assert(test1.serialize() == [0, 0, 0, 1, 2, 0, 3]);
	assert(deserialize!Test1([0, 0, 0, 1, 4, 12]) == Test1(1, 0, 4, 12));

	test1.a = 0;
	assert(test1.serialize() == [0, 0, 0, 0, 2, 0]);
	assert(deserialize!Test1([0, 0, 0, 0, 0, 0, 0, 0]) == Test1(0, 0, 0, 0));

	struct Test2 {

		ubyte[] a;

		@Length!ushort ushort[] b;

		@NoLength uint[] c;

	}

	Test2 test2 = Test2([1, 2], [3, 4], [5, 6]);
	assert(test2.serialize!(Endian.bigEndian, uint)() == [0, 0, 0, 2, 1, 2, 0, 2, 0, 3, 0, 4, 0, 0, 0, 5, 0, 0, 0, 6]);
	assert(deserialize!(Test2, Endian.bigEndian, uint)([0, 0, 0, 2, 1, 2, 0, 2, 0, 3, 0, 4, 0, 0, 0, 5, 0, 0, 0, 6, 1]) == test2);

	struct Test3 {

		@EndianLength!ushort(Endian.littleEndian) @LittleEndian ushort[] a;

		@NoLength ushort[] b;

	}

	Test3 test3 = Test3([1, 2], [3, 4]);
	assert(test3.serialize!(Endian.bigEndian)() == [2, 0, 1, 0, 2, 0, 0, 3, 0, 4]);

	struct Test4 {

		ubyte a;

		@LittleEndian uint b;

	}

	struct Test5 {

		@Length!ubyte Test4[] a;

		@NoLength Test4[] b;

	}

	Test5 test5 = Test5([Test4(1, 2)], [Test4(1, 2), Test4(3, 4)]);
	assert(test5.serialize() == [1, 1, 2, 0, 0, 0, 1, 2, 0, 0, 0, 3, 4, 0, 0, 0]);
	assert(deserialize!Test5([1, 1, 2, 0, 0, 0, 1, 2, 0, 0, 0, 3, 4, 0, 0, 0]) == test5);

}

@("nested Includes Excludes") unittest {
	
	struct Test1 {
		ubyte a;
		
		@Exclude {
			@EncodeOnly @Include ubyte b;
			
			@Condition("a==1") {
				ubyte c;
				@Include ubyte d;
				@Exclude ubyte e;
			}
			
			@Include @Exclude ubyte f;
			ubyte g;
			@Include ubyte h;
		}
	}
	{
		Test1 test1 = Test1(1, 2, 3, 4, 5, 6, 7, 8);
		assert(test1.serialize() == [1, 2, 3, 4, 8]);
		assert(deserialize!Test1([2, 1, 4]) == Test1(2, 0, 0, 1, 0, 0, 0, 4));
	}
	{
		Test1 test1 = Test1(128, 2, 3, 4, 5, 6, 7, 8);
		assert(test1.serialize() == [128, 2, 4, 8]);
	}
	
}

@("includer & excluder groups") unittest {
	
	enum G;
	enum N;
	
	struct Test1 {
		@Exclude:
		@G ubyte a;
		
		@Include @N ubyte b;
		
		@Condition("a==1") @G ubyte c;
		@G {
			ubyte d;
			@N ubyte e;
		}
	}
	{
		Test1 test1 = Test1(1, 2, 3, 4, 5);
		assert(test1.serialize() == [2, 3]);
		assert(Grouped!(Includer!G).serialize(test1) == [1, 2, 3, 4, 5]);
		assert(Grouped!(Includer!G, Excluder!N).serialize(test1) == [1, 3, 4]);
		assert(Grouped!(Includer!N).serialize(test1) == [2, 3, 5]);
		
		assert(deserialize!Test1([2]) == Test1(0, 2, 0, 0, 0));
		assert(Grouped!(Includer!G).deserialize!Test1([1, 2, 3, 4, 5]) == Test1(1, 2, 3, 4, 5));
		assert(Grouped!(Includer!G, Excluder!N).deserialize!Test1([1, 3, 4]) == Test1(1, 0, 3, 4, 0));
		assert(Grouped!(Includer!N).deserialize!Test1([2, 5]) == Test1(0, 2, 0, 0, 5));
	}
	{
		Test1 test1 = Test1(6, 2, 3, 4, 5);
		assert(test1.serialize() == [2]);
		assert(Grouped!(Includer!G).serialize(test1) == [6, 2, 3, 4, 5]);
		assert(Grouped!(Includer!G, Excluder!N).serialize(test1) == [6, 3, 4]);
		assert(Grouped!(Includer!N).serialize(test1) == [2, 5]);
		
		assert(deserialize!Test1([2]) == Test1(0, 2, 0, 0, 0));
		assert(Grouped!(Includer!G).deserialize!Test1([6, 2, 3, 4, 5]) == Test1(6, 2, 3, 4, 5));
		assert(Grouped!(Includer!G, Excluder!N).deserialize!Test1([6, 3, 4]) == Test1(6, 0, 3, 4, 0));
		assert(Grouped!(Includer!N).deserialize!Test1([2, 5]) == Test1(0, 2, 0, 0, 5));
	}
	
}

@("struct groups") unittest {
	
	struct G { int id; }
	
	struct Test1 {
		@Exclude:
		@G ubyte a;
		@G(0) ubyte b;
		@G(1) @G(2) ubyte c;
	}
	
	Test1 test1 = Test1(1, 2, 3);
	assert(test1.serialize() == []);
	assert(Grouped!(Includer!G).serialize(test1) == [1]);
	assert(Grouped!(Includer!(G(0))).serialize(test1) == [1, 2]);
	assert(Grouped!(Includer!(G(1))).serialize(test1) == [1, 3]);
	assert(Grouped!(Includer!(G(0)),Includer!(G(1))).serialize(test1) == [1, 2, 3]);
	assert(Grouped!(Includer!(G(0)),Includer!(G(1)), Excluder!(G(2))).serialize(test1) == [1, 2]);
	
	assert(Grouped!(Includer!G).deserialize!Test1([1]) == Test1(1, 0, 0));
	assert(Grouped!(Includer!(G(0))).deserialize!Test1([1, 2]) == Test1(1, 2, 0));
	assert(Grouped!(Includer!(G(1))).deserialize!Test1([1, 3]) == Test1(1, 0, 3));
	assert(Grouped!(Includer!(G(0)),Includer!(G(1))).deserialize!Test1([1, 2, 3]) == Test1(1, 2, 3));
	assert(Grouped!(Includer!(G(0)),Includer!(G(1)), Excluder!(G(2))).deserialize!Test1([1, 2]) == Test1(1, 2, 0));
	
}

@("using buffer") unittest {

	Buffer buffer = new Buffer(64);

	serialize(ubyte(55), buffer);
	assert(buffer.data.length == 1);
	assert(buffer.data!ubyte == [55]);

	assert(deserialize!ubyte(buffer) == 55);
	assert(buffer.data.length == 0);

}
