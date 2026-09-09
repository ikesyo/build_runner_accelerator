import 'package:json_annotation/json_annotation.dart';

part 'model_492.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model492 {
  const Model492({required this.id, required this.value});

  final int id;
  final String value;

  factory Model492.fromJson(Map<String, dynamic> json) =>
      _$Model492FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model492ToJson(this);
}
