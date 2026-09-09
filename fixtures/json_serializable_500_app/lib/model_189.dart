import 'package:json_annotation/json_annotation.dart';

part 'model_189.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model189 {
  const Model189({required this.id, required this.value});

  final int id;
  final String value;

  factory Model189.fromJson(Map<String, dynamic> json) =>
      _$Model189FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model189ToJson(this);
}
