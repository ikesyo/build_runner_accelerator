import 'package:json_annotation/json_annotation.dart';

part 'model_079.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model079 {
  const Model079({required this.id, required this.value});

  final int id;
  final String value;

  factory Model079.fromJson(Map<String, dynamic> json) =>
      _$Model079FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model079ToJson(this);
}
