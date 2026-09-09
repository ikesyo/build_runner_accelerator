// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'serializable.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$SerializableUser {

 int get id; String get displayName;
/// Create a copy of SerializableUser
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SerializableUserCopyWith<SerializableUser> get copyWith => _$SerializableUserCopyWithImpl<SerializableUser>(this as SerializableUser, _$identity);

  /// Serializes this SerializableUser to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SerializableUser&&(identical(other.id, id) || other.id == id)&&(identical(other.displayName, displayName) || other.displayName == displayName));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,displayName);

@override
String toString() {
  return 'SerializableUser(id: $id, displayName: $displayName)';
}


}

/// @nodoc
abstract mixin class $SerializableUserCopyWith<$Res>  {
  factory $SerializableUserCopyWith(SerializableUser value, $Res Function(SerializableUser) _then) = _$SerializableUserCopyWithImpl;
@useResult
$Res call({
 int id, String displayName
});




}
/// @nodoc
class _$SerializableUserCopyWithImpl<$Res>
    implements $SerializableUserCopyWith<$Res> {
  _$SerializableUserCopyWithImpl(this._self, this._then);

  final SerializableUser _self;
  final $Res Function(SerializableUser) _then;

/// Create a copy of SerializableUser
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? displayName = null,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as int,displayName: null == displayName ? _self.displayName : displayName // ignore: cast_nullable_to_non_nullable
as String,
  ));
}

}


/// Adds pattern-matching-related methods to [SerializableUser].
extension SerializableUserPatterns on SerializableUser {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _SerializableUser value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _SerializableUser() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _SerializableUser value)  $default,){
final _that = this;
switch (_that) {
case _SerializableUser():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _SerializableUser value)?  $default,){
final _that = this;
switch (_that) {
case _SerializableUser() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( int id,  String displayName)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _SerializableUser() when $default != null:
return $default(_that.id,_that.displayName);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( int id,  String displayName)  $default,) {final _that = this;
switch (_that) {
case _SerializableUser():
return $default(_that.id,_that.displayName);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( int id,  String displayName)?  $default,) {final _that = this;
switch (_that) {
case _SerializableUser() when $default != null:
return $default(_that.id,_that.displayName);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _SerializableUser implements SerializableUser {
  const _SerializableUser({required this.id, required this.displayName});
  factory _SerializableUser.fromJson(Map<String, dynamic> json) => _$SerializableUserFromJson(json);

@override final  int id;
@override final  String displayName;

/// Create a copy of SerializableUser
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$SerializableUserCopyWith<_SerializableUser> get copyWith => __$SerializableUserCopyWithImpl<_SerializableUser>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$SerializableUserToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _SerializableUser&&(identical(other.id, id) || other.id == id)&&(identical(other.displayName, displayName) || other.displayName == displayName));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,displayName);

@override
String toString() {
  return 'SerializableUser(id: $id, displayName: $displayName)';
}


}

/// @nodoc
abstract mixin class _$SerializableUserCopyWith<$Res> implements $SerializableUserCopyWith<$Res> {
  factory _$SerializableUserCopyWith(_SerializableUser value, $Res Function(_SerializableUser) _then) = __$SerializableUserCopyWithImpl;
@override @useResult
$Res call({
 int id, String displayName
});




}
/// @nodoc
class __$SerializableUserCopyWithImpl<$Res>
    implements _$SerializableUserCopyWith<$Res> {
  __$SerializableUserCopyWithImpl(this._self, this._then);

  final _SerializableUser _self;
  final $Res Function(_SerializableUser) _then;

/// Create a copy of SerializableUser
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? displayName = null,}) {
  return _then(_SerializableUser(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as int,displayName: null == displayName ? _self.displayName : displayName // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
