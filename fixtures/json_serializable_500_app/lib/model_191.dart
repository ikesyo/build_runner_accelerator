import 'package:json_annotation/json_annotation.dart';

part 'model_191.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model191 {
  const Model191({required this.id, required this.value});

  final int id;
  final String value;

  factory Model191.fromJson(Map<String, dynamic> json) =>
      _$Model191FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model191ToJson(this);
}
