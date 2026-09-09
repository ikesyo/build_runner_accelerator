import 'package:json_annotation/json_annotation.dart';

part 'model_283.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model283 {
  const Model283({required this.id, required this.value});

  final int id;
  final String value;

  factory Model283.fromJson(Map<String, dynamic> json) =>
      _$Model283FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model283ToJson(this);
}
