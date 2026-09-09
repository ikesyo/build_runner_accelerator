import 'package:json_annotation/json_annotation.dart';

part 'model_174.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model174 {
  const Model174({required this.id, required this.value});

  final int id;
  final String value;

  factory Model174.fromJson(Map<String, dynamic> json) =>
      _$Model174FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model174ToJson(this);
}
