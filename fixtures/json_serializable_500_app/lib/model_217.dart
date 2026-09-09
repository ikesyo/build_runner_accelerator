import 'package:json_annotation/json_annotation.dart';

part 'model_217.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model217 {
  const Model217({required this.id, required this.value});

  final int id;
  final String value;

  factory Model217.fromJson(Map<String, dynamic> json) =>
      _$Model217FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model217ToJson(this);
}
