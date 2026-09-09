import 'package:json_annotation/json_annotation.dart';

part 'model_352.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model352 {
  const Model352({required this.id, required this.value});

  final int id;
  final String value;

  factory Model352.fromJson(Map<String, dynamic> json) =>
      _$Model352FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model352ToJson(this);
}
