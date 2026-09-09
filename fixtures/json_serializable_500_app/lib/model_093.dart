import 'package:json_annotation/json_annotation.dart';

part 'model_093.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model093 {
  const Model093({required this.id, required this.value});

  final int id;
  final String value;

  factory Model093.fromJson(Map<String, dynamic> json) =>
      _$Model093FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model093ToJson(this);
}
