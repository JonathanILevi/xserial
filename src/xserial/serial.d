module xserial.serial;

import std.system : Endian, sysEndian = endian;
import std.traits : isArray, isDynamicArray, isStaticArray, isAssociativeArray, ForeachType, KeyType, ValueType, isIntegral, isFloatingPoint, isSomeChar, isType, isCallable, isPointer, hasUDA, getUDAs, TemplateOf;
import std.typecons : isTuple;
import std.algorithm.searching : canFind;
import std.meta : AliasSeq;

import xbuffer.buffer : canSwapEndianness, Buffer, BufferOverflowException;
import xbuffer.memory : xalloc, xfree;
import xbuffer.varint : isVar;

import xserial.attribute;



enum EndianType {
	bigEndian	= cast(int)Endian.bigEndian	,
	littleEndian	= cast(int)Endian.littleEndian	,
	var		,
}
unittest {
	assert(EndianType.bigEndian!=EndianType.var);
	assert(EndianType.bigEndian!=cast(EndianType)-1);
}


/**
 * Copied and slightly modified from Phobos `std.traits`. (dlang.org/phobos/std_traits.html)
 */
private template isDesiredUDA(alias attribute, alias toCheck)
{
	/*added*/ import std.traits;
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


private bool isTemplateOf(alias UDA, alias Template)() {
	return is(UDA==Template!U,U...);
}


template Group(AddedUDAs...) {
	private auto getSerializeMembers(T, Only)() {
		alias UDAs = AliasSeq!(AddedUDAs,Includer!Include,Excluder!Exclude);
		
		struct Member{
			string name	;
			string condition	="";
		} 
		
		Member[] members;
		
		foreach(member; __traits(allMembers, T)) {
			string condition = "";
			static if(is(typeof(mixin("T." ~ member))) && !hasUDA!(__traits(getMember, T, member), Only)) {
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
		
		return members;
	}
	
	alias Deserializer = Serializer;
	template Serializer(Endian endianness, L=uint, Endian lengthEndianness=endianness) {
		alias Serializer = Serializer!(cast(EndianType)endianness, L, cast(EndianType)lengthEndianness);
	}
	template Serializer(EndianType endianness=cast(EndianType)sysEndian, L=uint, EndianType lengthEndianness=endianness) {
		// -------------
		// serialization
		// -------------
		
		/// Serialize Number
		void serialize(T)(T value, Buffer buffer) if(is(T:bool) || isIntegral!T || isFloatingPoint!T || isSomeChar!T) {
			static if(endianness == EndianType.var) {
				static assert(isIntegral!T && T.sizeof > 1, T.stringof ~ " cannot be annotated with @Var");
				buffer.writeVar!T(value);
			}
			else static if(endianness == EndianType.bigEndian) {
				buffer.write!(Endian.bigEndian, T)(value);
			}
			else static if(endianness == EndianType.littleEndian) {
				buffer.write!(Endian.littleEndian, T)(value);
			}
		}
		/// Serialize Static Array
		void serialize(T)(T value, Buffer buffer) if(isStaticArray!T) {
			serializeArrayDataImpl(value, buffer);
		}
		/// Serialize Dynamic Array && Associative Array
		void serialize(bool serializeLength=true, T)(T value, Buffer buffer) if(isDynamicArray!T || isAssociativeArray!T) {
			static if (serializeLength) {
				static if(L.sizeof < size_t.sizeof)
					Serializer!(lengthEndianness, L, lengthEndianness).serialize(cast(L)value.length, buffer);
				else	Serializer!(lengthEndianness, L, lengthEndianness).serialize(value.length, buffer);
			}
			// Dynamic Array
			static if (isDynamicArray!T) {
				serializeArrayDataImpl(value, buffer);
			}
			// AssociativeArray
			else static if (isAssociativeArray!T){
				foreach(key, v; value) {
					serialize(key, buffer);
					serialize(v, buffer);
				}
			}
		}
		/// Serialize normal array excluding length (used for dynamic and static arrays)
		private void serializeArrayDataImpl(T)(T value, Buffer buffer) {
			static assert(isArray!T);
			static if(	canSwapEndianness!(ForeachType!T)	
				&& !is(ForeachType!T == struct)	
				&& endianness != EndianType.var	) 
			{
				static assert(!is(ForeachType!T == class	), "internal error; submit a bug report");
				static assert(!is(ForeachType!T == interface	), "internal error; submit a bug report");
				buffer.write!(cast(Endian)endianness)(value);
			}
			else {
				foreach(v ; value) {
					serialize(v, buffer);
				}
			}
		}
		/// Serialize Tuple
		void serialize(T)(T value, Buffer buffer) if(isTuple!T) {
			static foreach(i ; 0..value.fieldNames.length) {
				serialize(value[i], buffer);
			}
		}
		/// Serialize Members (Class || Struct || Interface)
		void serialize(T)(T value, Buffer buffer) if(!isTuple!T && (is(T == class) || is(T == struct) || is(T == interface))) {
			static if(__traits(hasMember, T, "serialize") && __traits(compiles, value.serialize(buffer))) {
				value.serialize(buffer);
				return;
			}
			else {
				enum serMems = getSerializeMembers!(T, DecodeOnly);
				static foreach(member; serMems) {{
					bool conditionGood = member.condition.length==0;
					static if (member.condition.length!=0) {
						mixin("with(value){if("~member.condition~"){conditionGood=true;}}");
					}		
					if (conditionGood) {
						mixin("alias M = typeof(value."~member.name~");");
						
						//---Custom UDA
						static if (hasUDA!(__traits(getMember, T, member.name), Custom)) {
							alias Found = getUDAs!(__traits(getMember, T, member.name), Custom);
							Found[Found.length-1].C.serialize(mixin("value."~member.name), buffer);
						}
						//---Normal
						else {
							//---get new attributes
							static foreach_reverse (uda; __traits(getAttributes, mixin("value."~member.name))) {
								static if (isTemplateOf!(uda,Length) || (__traits(compiles, typeof(uda)) && !(is(typeof(uda)==void)) && isTemplateOf!(typeof(uda),Length))) {
									static if (__traits(compiles, uda.Type) && !is(typeof(NewLengthGiven))) {
										enum NewLengthGiven = true;
										alias NewLength = uda.Type;
									}
									static if (__traits(compiles, uda.endianness==-1) && uda.endianness!=-1 && !is(typeof(newLengthEndianness))) {
										enum newLengthEndianness = uda.endianness;
									}
								}
							}
							static if (!is(typeof(NewLengthGiven))) {
								alias NewLength = L;
							}
							static if (!is(typeof(newLengthEndianness))) {
								enum newLengthEndianness = lengthEndianness;
							}
							
							static if(hasUDA!(__traits(getMember, T, member.name), NoLength)) {
								enum noLength = true;
							}
							
							static foreach_reverse (uda; __traits(getAttributes, __traits(getMember, T, member.name))) {
								static if (isDesiredUDA!(uda, Var)) {
									enum newEndianness = EndianType.var;
								}
								else static if (isDesiredUDA!(uda, BigEndian)) {
									enum newEndianness = EndianType.bigEndian;
								}
								else static if (isDesiredUDA!(uda, LittleEndian)) {
									enum newEndianness = EndianType.littleEndian;
								}
							}
							static if (!is(typeof(newEndianness))) {
								enum newEndianness = endianness;
							}
							
							//--do
							static if (is(typeof(noLength))) {
								static assert(isDynamicArray!M || isAssociativeArray!M);
								Serializer!(newEndianness, NewLength, newLengthEndianness).serialize!false(mixin("value."~member.name), buffer);
							}
							else {
								Serializer!(newEndianness, NewLength, newLengthEndianness).serialize(mixin("value."~member.name), buffer);
							}
						}
					}
				}}
			}
		}
		
		/// Without Buffer
		ubyte[] serialize(T)(T value) {
			Buffer buffer = xalloc!Buffer(64);
			scope(exit) xfree(buffer);
			serialize(value, buffer);
			return buffer.data!ubyte.dup;
		}
		/// ditto
		ubyte[] serialize(bool serializeLength, T)(T value) if(isDynamicArray!T || isAssociativeArray!T) {
			Buffer buffer = xalloc!Buffer(64);
			scope(exit) xfree(buffer);
			serialize!serializeLength(value, buffer);
			return buffer.data!ubyte.dup;
		}
		
		
		// ---------------
		// deserialization
		// ---------------
		
		/// Deserialize Number
		T deserialize(T)(Buffer buffer) if(is(T : bool) || isIntegral!T || isFloatingPoint!T || isSomeChar!T) {
			static if(endianness == EndianType.var) {
				static assert(isIntegral!T && T.sizeof > 1, T.stringof ~ " cannot be annotated with @Var");
				return buffer.readVar!T();
			}
			else static if(endianness == EndianType.bigEndian) {
				return buffer.read!(Endian.bigEndian, T)();
			}
			else static if(endianness == EndianType.littleEndian) {
				return buffer.read!(Endian.littleEndian, T)();
			}
		}
		/// Deserialize Static Array
		T deserialize(T)(Buffer buffer) if(isStaticArray!T) {
			T ret;
			foreach(i ; 0..ret.length) {
				ret[i] = deserialize!(ForeachType!T)(buffer);
			}
			return ret;
		}
		/// Deserialize Dynamic Array && Associative Array
		T deserialize(T, bool serializeLength=true)(Buffer buffer) if(isDynamicArray!T || isAssociativeArray!T) {
			static if (serializeLength) {
				auto length = Serializer!(lengthEndianness, L, lengthEndianness).deserialize!L(buffer);
				T value;
				foreach(_ ; 0..length) {
					// Dynamic Array
					static if (isDynamicArray!T) {
						value ~= deserialize!(ForeachType!T)(buffer);
					}
					// AssociativeArray
					else static if (isAssociativeArray!T){
						value[deserialize!(KeyType!T)(buffer)] = deserialize!(ValueType!T)(buffer);
					}
				}
				return value;
			}
			else {
				T value;
				try {
					while(true) {
						// Dynamic Array
						static if (isDynamicArray!T) {
							value ~= deserialize!(ForeachType!T)(buffer);
						}
						// AssociativeArray
						else static if (isAssociativeArray!T){
							value[deserialize!(KeyType!T)(buffer)] = deserialize!(ValueType!T)(buffer);
						}
					}
				} catch(BufferOverflowException) {}
				return value;
			}
		}
		/// Deserialize Tuple
		T deserialize(T)(Buffer buffer) if(isTuple!T) {
			T value;
			static foreach(i, U; T.Types) {
				value[i] = deserialize!U(buffer);
			}
			return value;
		}
		/// Deserialize Members (Class || Struct || Interface)
		T deserialize(T)(Buffer buffer) if(!isTuple!T && (is(T == class) || is(T == struct) || is(T == interface))) {
			T value;
			static if(is(T == class))
				value = new T();
			else static assert(!is(T==interface), "To deserialize an interface you must provide an instance to deserialize to.  `deserialize(instance,data)`");
			return deserialize(value, buffer);
		}
		/// ditto
		T deserialize(T)(T value, Buffer buffer) if(!isTuple!T && (is(T == class) || is(T == struct) || is(T == interface))) {
			static if(__traits(hasMember, T, "deserialize") && __traits(compiles, value.deserialize(buffer))) {
				value.deserialize(buffer);
				return value;
			}
			else {
				enum serMems = getSerializeMembers!(T, EncodeOnly);
				static foreach(member; serMems) {{
					bool conditionGood = member.condition.length==0;
					static if (member.condition.length!=0) {
						mixin("with(value){if("~member.condition~"){conditionGood=true;}}");
					}
					if (conditionGood) {
						mixin("alias M = typeof(value."~member.name~");");
						
						//---Custom UDA
						static if (hasUDA!(__traits(getMember, T, member.name), Custom)) {
							alias Found = getUDAs!(__traits(getMember, T, member.name), Custom);
							mixin("value."~member.name) = Found[Found.length-1].C.deserialize(buffer);
						}
						//---Normal
						else {
							//---get new attributes
							static foreach_reverse (uda; __traits(getAttributes, mixin("value."~member.name))) {
								static if (isTemplateOf!(uda,Length) || (__traits(compiles, typeof(uda)) && !(is(typeof(uda)==void)) && isTemplateOf!(typeof(uda),Length))) {
									static if (__traits(compiles, uda.Type) && !is(typeof(NewLengthGiven))) {
										enum NewLengthGiven = true;
										alias NewLength = uda.Type;
									}
									static if (__traits(compiles, uda.endianness==-1) && uda.endianness!=-1 && !is(typeof(newLengthEndianness))) {
										enum newLengthEndianness = uda.endianness;
									}
								}
							}
							static if (!is(typeof(NewLengthGiven))) {
								alias NewLength = L;
							}
							static if (!is(typeof(newLengthEndianness))) {
								enum newLengthEndianness = lengthEndianness;
							}
							
							static if(hasUDA!(__traits(getMember, T, member.name), NoLength)) {
								enum noLength = true;
							}
							
							static foreach_reverse (uda; __traits(getAttributes, __traits(getMember, T, member.name))) {
								static if (isDesiredUDA!(uda, Var)) {
									enum newEndianness = EndianType.var;
								}
								else static if (isDesiredUDA!(uda, BigEndian)) {
									enum newEndianness = EndianType.bigEndian;
								}
								else static if (isDesiredUDA!(uda, LittleEndian)) {
									enum newEndianness = EndianType.littleEndian;
								}
							}
							static if (!is(typeof(newEndianness))) {
								enum newEndianness = endianness;
							}
							
							//--do
							static if (is(typeof(noLength))) {
								static assert(isDynamicArray!M || isAssociativeArray!M);
								mixin("value."~member.name) = Serializer!(newEndianness, NewLength, newLengthEndianness).deserialize!(M,false)(buffer);
							}
							else {
								mixin("value."~member.name) = Serializer!(newEndianness, NewLength, newLengthEndianness).deserialize!M(buffer);
							}
						}
					}
				}}
				return value;
			}
		}
		/// Without Buffer
		T deserialize(T)(const(ubyte)[] data) {
			Buffer buffer = xalloc!Buffer(data);
			scope(exit) xfree(buffer);
			return deserialize!T(buffer);
		}
		/// ditto
		T deserialize(T, bool serializeLength)(const(ubyte)[] data) if(isDynamicArray!T || isAssociativeArray!T) {
			Buffer buffer = xalloc!Buffer(data);
			scope(exit) xfree(buffer);
			return deserialize!(T, serializeLength)(buffer);
		}
		/// ditto
		T deserialize(T)(T value, const(ubyte)[] data) if(!isTuple!T && (is(T == class) || is(T == struct) || is(T == interface))) {
			Buffer buffer = xalloc!Buffer(data);
			scope(exit) xfree(buffer);
			return deserialize(value, buffer);
		}
	}
	
	alias serialize	= Serializer!().serialize	;
	alias deserialize	= Serializer!().deserialize	;
	void serialize(EndianType endianness, L=uint, EndianType lengthEndianness=endianness, T)(T value, Buffer buffer) {
		Serializer!(endianness, L, lengthEndianness).serialize(value, buffer);
	}
	ubyte[] serialize(EndianType endianness, L=uint, EndianType lengthEndianness=endianness, T)(T value) {
		return Serializer!(endianness, L, lengthEndianness).serialize(value);
	}
	void serialize(Endian endianness, L=uint, Endian lengthEndianness=endianness, T)(T value, Buffer buffer) {
		Serializer!(cast(EndianType)endianness, L, cast(EndianType)lengthEndianness).serialize(value, buffer);
	}
	ubyte[] serialize(Endian endianness, L=uint, Endian lengthEndianness=endianness, T)(T value) {
		return Serializer!(cast(EndianType)endianness, L, cast(EndianType)lengthEndianness).serialize(value);
	}
	
	T deserialize(T, EndianType endianness, L=uint, EndianType lengthEndianness=endianness)(Buffer buffer) {
		return Serializer!(endianness, L, lengthEndianness).deserialize!T(buffer);
	}
	T deserialize(T, EndianType endianness, L=uint, EndianType lengthEndianness=endianness)(const(ubyte)[] data) {
		return Serializer!(endianness, L, lengthEndianness).deserialize!T(data);
	}
	T deserialize(T, Endian endianness, L=uint, Endian lengthEndianness=endianness)(Buffer buffer) {
		return Serializer!(cast(EndianType)endianness, L, cast(EndianType)lengthEndianness).deserialize!T(buffer);
	}
	T deserialize(T, Endian endianness, L=uint, Endian lengthEndianness=endianness)(const(ubyte)[] data) {
		return Serializer!(cast(EndianType)endianness, L, cast(EndianType)lengthEndianness).deserialize!T(data);
	}
	
	T deserialize(EndianType endianness, L=uint, EndianType lengthEndianness=endianness, T)(T value, Buffer buffer) if(!isTuple!T && (is(T == class) || is(T == struct) || is(T == interface))) {
		return Serializer!(endianness, L, lengthEndianness).deserialize(value, buffer);
	}
	T deserialize(EndianType endianness, L=uint, EndianType lengthEndianness=endianness, T)(T value, const(ubyte)[] data) if(!isTuple!T && (is(T == class) || is(T == struct) || is(T == interface))) {
		return Serializer!(endianness, L, lengthEndianness).deserialize(value, data);
	}
	T deserialize(Endian endianness, L=uint, Endian lengthEndianness=endianness, T)(T value, Buffer buffer) if(!isTuple!T && (is(T == class) || is(T == struct) || is(T == interface))) {
		return Serializer!(cast(EndianType)endianness, L, cast(EndianType)lengthEndianness).deserialize(value, buffer);
	}
	T deserialize(Endian endianness, L=uint, Endian lengthEndianness=endianness, T)(T value, const(ubyte)[] data) if(!isTuple!T && (is(T == class) || is(T == struct) || is(T == interface))) {
		return Serializer!(cast(EndianType)endianness, L, cast(EndianType)lengthEndianness).deserialize(value, data);
	}
}

alias serialize	= Group!().serialize	;
alias deserialize	= Group!().deserialize	;
alias Serializer	= Group!().Serializer	;
alias Deserializer	= Group!().Deserializer	;



// ---------
// unittests
// ---------

@("numbers") unittest {
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
		@Length @Length!ushort ushort[] b;
		@NoLength uint[] c;
	}
	
	Test2 test2 = Test2([1, 2], [3, 4], [5, 6]);
	assert(test2.serialize!(Endian.bigEndian, uint)() == [0, 0, 0, 2, 1, 2, 0, 2, 0, 3, 0, 4, 0, 0, 0, 5, 0, 0, 0, 6]);
	assert(deserialize!(Test2, Endian.bigEndian, uint)([0, 0, 0, 2, 1, 2, 0, 2, 0, 3, 0, 4, 0, 0, 0, 5, 0, 0, 0, 6]) == test2);
	
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
		assert(Group!(Includer!G).serialize(test1) == [1, 2, 3, 4, 5]);
		assert(Group!(Includer!G, Excluder!N).serialize(test1) == [1, 3, 4]);
		assert(Group!(Includer!N).serialize(test1) == [2, 3, 5]);
		
		assert(deserialize!Test1([2]) == Test1(0, 2, 0, 0, 0));
		assert(Group!(Includer!G).deserialize!Test1([1, 2, 3, 4, 5]) == Test1(1, 2, 3, 4, 5));
		assert(Group!(Includer!G, Excluder!N).deserialize!Test1([1, 3, 4]) == Test1(1, 0, 3, 4, 0));
		assert(Group!(Includer!N).deserialize!Test1([2, 5]) == Test1(0, 2, 0, 0, 5));
	}
	{
		Test1 test1 = Test1(6, 2, 3, 4, 5);
		assert(test1.serialize() == [2]);
		assert(Group!(Includer!G).serialize(test1) == [6, 2, 3, 4, 5]);
		assert(Group!(Includer!G, Excluder!N).serialize(test1) == [6, 3, 4]);
		assert(Group!(Includer!N).serialize(test1) == [2, 5]);
		
		assert(deserialize!Test1([2]) == Test1(0, 2, 0, 0, 0));
		assert(Group!(Includer!G).deserialize!Test1([6, 2, 3, 4, 5]) == Test1(6, 2, 3, 4, 5));
		assert(Group!(Includer!G, Excluder!N).deserialize!Test1([6, 3, 4]) == Test1(6, 0, 3, 4, 0));
		assert(Group!(Includer!N).deserialize!Test1([2, 5]) == Test1(0, 2, 0, 0, 5));
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
	assert(Group!(Includer!G).serialize(test1) == [1]);
	assert(Group!(Includer!(G(0))).serialize(test1) == [1, 2]);
	assert(Group!(Includer!(G(1))).serialize(test1) == [1, 3]);
	assert(Group!(Includer!(G(0)),Includer!(G(1))).serialize(test1) == [1, 2, 3]);
	assert(Group!(Includer!(G(0)),Includer!(G(1)), Excluder!(G(2))).serialize(test1) == [1, 2]);
	
	assert(Group!(Includer!G).deserialize!Test1([1]) == Test1(1, 0, 0));
	assert(Group!(Includer!(G(0))).deserialize!Test1([1, 2]) == Test1(1, 2, 0));
	assert(Group!(Includer!(G(1))).deserialize!Test1([1, 3]) == Test1(1, 0, 3));
	assert(Group!(Includer!(G(0)),Includer!(G(1))).deserialize!Test1([1, 2, 3]) == Test1(1, 2, 3));
	assert(Group!(Includer!(G(0)),Includer!(G(1)), Excluder!(G(2))).deserialize!Test1([1, 2]) == Test1(1, 2, 0));
}

@("using buffer") unittest {
	Buffer buffer = new Buffer(64);
	
	serialize(ubyte(55), buffer);
	assert(buffer.data.length == 1);
	assert(buffer.data!ubyte == [55]);
	
	assert(deserialize!ubyte(buffer) == 55);
	assert(buffer.data.length == 0);
}

@("custom attrubute") unittest {
	struct CusNo {
		static void serialize(uint value, Buffer buffer) {
		}
		static uint deserialize(Buffer buffer) {
			return 0;
		}
	}
	struct Cus {
		static void serialize(uint value, Buffer buffer) {
			buffer.write((value+1).serialize!(Endian.bigEndian));
		}
		static uint deserialize(Buffer buffer) {
			return buffer.read!(Endian.bigEndian, int)-1;
		}
	}
	struct Test {
		@Custom!CusNo @Custom!Cus uint a;
	}
	
	Test test = Test(5);
	assert(test.serialize() == [0,0,0,6]);
	assert(deserialize!Test([0,0,0,6]) == test);
}

@("override length uda") unittest {
	{
		struct Test {
			@Length!ulong(EndianType.var) @Length!(ushort, EndianType.bigEndian) ubyte[] a;
		}
		
		Test test = Test([1,2]);
		assert(test.serialize!(EndianType.bigEndian)==[0,2,1,2]);
		assert([0,2,1,2].deserialize!(Test,EndianType.bigEndian)==test);
	}
	{
		struct Test2 {
			@Length!ulong(EndianType.var) @Length!(uint) @EndianLength!ushort @LittleEndianLength ubyte[] a;
		}
		
		Test2 test = Test2([1,2]);
		import std.stdio;
		assert(test.serialize!(EndianType.bigEndian)==[2,0,1,2]);
		assert([2,0,1,2].deserialize!(Test2,EndianType.bigEndian)==test);
	}
}

@("interface and deserialize to instance") unittest {
	interface ITest {
		@LittleEndianLength @Include @property {
			ubyte[] aa();
			void aa(ubyte[]);
		}
		@property {
			ubyte cc();
		}
	}
	class Test : ITest {
		@Length!ubyte ushort[] a;
		@Exclude ubyte b;
		ubyte c;
		
		this(ushort[] a, ubyte b, ubyte c) {
			this.a = a;
			this.b = b;
			this.c = c;
		}
		
		@property {
			import std.algorithm, std.array;
			ubyte[] aa() {
				return a.map!((v){return cast(ubyte)v;}).array;
			}
			void aa(ubyte[] n) {
				a = n.map!((v){return cast(ushort)v;}).array;
			}
			ubyte cc() {
				return c;
			}
		}
	}
	
	Test test = new Test([1,2], 3, 4);
	test.deserialize!(EndianType.bigEndian)([5,0,1,0,2,0,3,0,4,0,5,6]);
	assert(test.a==[1,2,3,4,5] && test.b==3 && test.c==6);
	
	ITest iTest = test;
	iTest.deserialize!(EndianType.bigEndian)([2,0,0,0,1,2]);
	assert(test.a==[1,2] && test.b==3 && test.c==6);
	
	assert(iTest.serialize!(Endian.bigEndian) == [2,0,0,0,1,2]);
}

@("immutability") unittest {
	{
		ubyte[] test = [1,2,3,4];
		assert(test.serialize!(Endian.littleEndian, ubyte)==[4,1,2,3,4]);
		assert(test.deserialize!(ubyte[4]) == [1,2,3,4]);
	}
	{
		const(ubyte)[] test = [1,2,3,4];
		assert(test.serialize!(Endian.littleEndian, ubyte)==[4,1,2,3,4]);
		assert(test.deserialize!(ubyte[4]) == [1,2,3,4]);
	}
	{
		immutable(ubyte)[] test = [1,2,3,4];
		assert(test.serialize!(Endian.littleEndian, ubyte)==[4,1,2,3,4]);
		assert(test.deserialize!(ubyte[4]) == [1,2,3,4]);
	}
	{
		const(ubyte[]) test = [1,2,3,4];
		assert(test.serialize!(Endian.littleEndian, ubyte)==[4,1,2,3,4]);
		assert(test.deserialize!(ubyte[4]) == [1,2,3,4]);
	}
	{
		immutable(ubyte[]) test = [1,2,3,4];
		assert(test.serialize!(Endian.littleEndian, ubyte)==[4,1,2,3,4]);
		assert(test.deserialize!(ubyte[4]) == [1,2,3,4]);
	}
	{
		struct Test {
			ubyte a;
		}
		{
			Test test = Test(1);
			assert(test.serialize==[1]);
		}
		{
			const Test test = Test(1);
			assert(test.serialize==[1]);
		}
		{
			immutable Test test = Test(1);
			assert(test.serialize==[1]);
		}
	}
}

// for code coverage: because the coverage report does not understand CTFE
unittest{
	enum G;
	enum N;
	struct Test1 {
		ubyte z;
		@Exclude:
		@G ubyte a;
		
		@Include @N ubyte b;
		
		@Condition("a==1") ubyte c;
		@G {
			ubyte d;
			@N ubyte e;
		}
	}
	auto test1 = Group!(Includer!G, Excluder!N).getSerializeMembers!(Test1, EncodeOnly);
}
