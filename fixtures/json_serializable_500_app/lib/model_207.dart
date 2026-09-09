import 'package:json_annotation/json_annotation.dart';

part 'model_207.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model207 {
  const Model207({required this.id, required this.value});

  final int id;
  final String value;

  factory Model207.fromJson(Map<String, dynamic> json) =>
      _$Model207FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model207ToJson(this);
}
