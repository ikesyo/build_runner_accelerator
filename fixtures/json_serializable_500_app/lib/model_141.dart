import 'package:json_annotation/json_annotation.dart';

part 'model_141.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model141 {
  const Model141({required this.id, required this.value});

  final int id;
  final String value;

  factory Model141.fromJson(Map<String, dynamic> json) =>
      _$Model141FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model141ToJson(this);
}
