import 'package:json_annotation/json_annotation.dart';

part 'model_043.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model043 {
  const Model043({required this.id, required this.value});

  final int id;
  final String value;

  factory Model043.fromJson(Map<String, dynamic> json) =>
      _$Model043FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model043ToJson(this);
}
