// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'serializable.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_SerializableUser _$SerializableUserFromJson(Map<String, dynamic> json) =>
    _SerializableUser(
      id: (json['id'] as num).toInt(),
      displayName: json['displayName'] as String,
    );

Map<String, dynamic> _$SerializableUserToJson(_SerializableUser instance) =>
    <String, dynamic>{'id': instance.id, 'displayName': instance.displayName};
