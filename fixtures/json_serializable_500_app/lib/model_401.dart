import 'package:json_annotation/json_annotation.dart';

part 'model_401.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model401 {
  const Model401({required this.id, required this.value});

  final int id;
  final String value;

  factory Model401.fromJson(Map<String, dynamic> json) =>
      _$Model401FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model401ToJson(this);
}
