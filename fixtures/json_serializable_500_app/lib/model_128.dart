import 'package:json_annotation/json_annotation.dart';

part 'model_128.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model128 {
  const Model128({required this.id, required this.value});

  final int id;
  final String value;

  factory Model128.fromJson(Map<String, dynamic> json) =>
      _$Model128FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model128ToJson(this);
}
