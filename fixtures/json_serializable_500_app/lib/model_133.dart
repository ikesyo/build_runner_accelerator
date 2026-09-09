import 'package:json_annotation/json_annotation.dart';

part 'model_133.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model133 {
  const Model133({required this.id, required this.value});

  final int id;
  final String value;

  factory Model133.fromJson(Map<String, dynamic> json) =>
      _$Model133FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model133ToJson(this);
}
