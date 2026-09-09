import 'package:json_annotation/json_annotation.dart';

part 'model_072.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model072 {
  const Model072({required this.id, required this.value});

  final int id;
  final String value;

  factory Model072.fromJson(Map<String, dynamic> json) =>
      _$Model072FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model072ToJson(this);
}
