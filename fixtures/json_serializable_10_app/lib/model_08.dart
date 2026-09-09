import 'package:json_annotation/json_annotation.dart';

part 'model_08.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model08 {
  const Model08({required this.id, required this.value});

  final int id;
  final String value;

  factory Model08.fromJson(Map<String, dynamic> json) =>
      _$Model08FromJson(json);

  Map<String, dynamic> toJson() => _$Model08ToJson(this);
}
